module Kulla
  # Rack middleware behind kulla_beacon_tag. The browser posts to the app's own /kulla/visit so the
  # Kulla token never reaches it; this turns the beacon into a `visit` event and answers 204.
  class VisitEndpoint
    PATH = "/kulla/visit".freeze
    # Content-Security-Policy reports: point the app's policy at it (policy.report_uri "/kulla/csp").
    CSP_PATH = "/kulla/csp".freeze
    MAX_BODY_BYTES = 4_096
    MAX_REPORT_BYTES = 8_192 # error and CSP reports carry a stack or a policy excerpt
    ORIGIN = %r{(?:https?://[^/\s)]+|webpack-internal://)}
    DIGEST = /-[0-9a-f]{8,64}(?=\.(?:js|css|mjs))/
    DEVICES = %w[phone tablet desktop].freeze

    def initialize(app, client: nil, secret: nil)
      @app = app
      @client = client
      @secret = secret
    end

    def call(env)
      path = env["PATH_INFO"]
      return @app.call(env) unless path == PATH || path == CSP_PATH
      return [ 405, { "allow" => "POST" }, [] ] unless env["REQUEST_METHOD"] == "POST"

      path == CSP_PATH ? record_csp(env) : record(env)
      [ 204, {}, [] ]
    end

    private
      def record(env)
        client = @client || Kulla.client
        return unless client.config.enabled? && client.config.capture?(:visits)
        # Browsers mark beacons with Sec-Fetch-Site; ignore anything posted from another site.
        site = env["HTTP_SEC_FETCH_SITE"]
        return if site && !%w[same-origin none].include?(site)

        data, size = parse(env["rack.input"])
        return if data.nil?
        return record_browser_error(client, data) if data["type"] == "error"
        return if size > MAX_BODY_BYTES

        ua = env["HTTP_USER_AGENT"].to_s
        attrs = self.class.visit_attrs(data, ua: ua, visitor: visitor(ip(env), ua))
        client.track("visit", attrs, scrub: false) if attrs["path"]
      rescue StandardError => e
        Kulla.log("visit endpoint failed: #{e.class}: #{e.message}")
      end

      # A JavaScript error or unhandled rejection from the page -> `error` with source "browser".
      def record_browser_error(client, data)
        return unless client.config.capture?(:browser_errors)
        name = Scrubber.clean_string(data["name"].to_s[/\A[\w.$]{1,80}/] || "Error", 80)
        message = Scrubber.clean_string(data["message"].to_s, 500)
        frames = data["stack"].to_s.lines.map { |l| l.strip.sub(/\Aat /, "") }.reject(&:empty?)
                              .reject { |l| l.start_with?(name) && l.include?(message[0, 20].to_s) }
                              .first(20).map { |l| self.class.clean_frame(l) }
        attrs = { "class" => name, "message" => message, "backtrace" => frames, "handled" => false, "severity" => "error",
                  "source" => "browser", "context" => { "path" => self.class.send(:local_path, data["path"]), "device" => DEVICES.include?(data["device"]) ? data["device"] : nil }.compact }
        client.track("error", attrs, level: :error, message: "#{name}: #{message}", scrub: false)
      end

      # A CSP violation report (report-uri or Reporting API) -> `csp`.
      def record_csp(env)
        client = @client || Kulla.client
        return unless client.config.enabled? && client.config.capture?(:csp)
        data = parse_any(env["rack.input"])
        reports = data.is_a?(Array) ? data.map { |r| r["body"] }.compact : [ data&.dig("csp-report") ].compact
        reports.first(5).each do |r|
          attrs = {
            "directive" => (r["effective-directive"] || r["effectiveDirective"] || r["violated-directive"]).to_s[0, 80],
            "blocked" => self.class.blocked(r["blocked-uri"] || r["blockedURL"]),
            "path" => self.class.send(:local_path, URI.parse((r["document-uri"] || r["documentURL"]).to_s).path.to_s),
            "source" => self.class.clean_frame((r["source-file"] || r["sourceFile"]).to_s)[0, 200],
            "disposition" => (r["disposition"] || "enforce").to_s[0, 20]
          }.reject { |_, v| v.nil? || v == "" }
          client.track("csp", attrs, level: :warn, scrub: false)
        end
      rescue StandardError => e
        Kulla.log("csp endpoint failed: #{e.class}: #{e.message}")
      end

      def parse_any(input)
        return if input.nil?
        input.rewind if input.respond_to?(:rewind)
        body = input.read(MAX_REPORT_BYTES + 1)
        return if body.nil? || body.bytesize > MAX_REPORT_BYTES
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def parse(input)
        return if input.nil?
        # Rack::MethodOverride may already have read a form-encoded body.
        input.rewind if input.respond_to?(:rewind)
        body = input.read(MAX_REPORT_BYTES + 1)
        return if body.nil? || body.bytesize > MAX_REPORT_BYTES

        data = JSON.parse(body)
        data.is_a?(Hash) ? [ data, body.bytesize ] : nil
      rescue JSON::ParserError
        nil
      end

      def ip(env)
        (env["action_dispatch.remote_ip"] || env["REMOTE_ADDR"]).to_s
      end

      # Rotates daily: yesterday's visitor ids can't be linked to today's.
      def visitor(ip, ua)
        salt = "#{Time.now.utc.strftime("%Y-%m-%d")}#{secret}"
        Digest::SHA256.hexdigest("#{salt}#{ip}#{ua}")[0, 16]
      end

      def secret
        @secret ||=
          if defined?(Rails) && Rails.respond_to?(:application) && Rails.application.respond_to?(:secret_key_base)
            Rails.application.secret_key_base.to_s
          else
            Kulla.config.auth_token.to_s
          end
      end

      class << self
        # "https://app.com/assets/application-3f9a1c2b.js:1:2345" -> "/assets/application.js:1:2345"
        def clean_frame(line) = line.to_s.gsub(ORIGIN, "").gsub(DIGEST, "")[0, 300]

        # Only the origin or keyword of what was blocked, never a full URL with its query.
        def blocked(value)
          value = value.to_s
          return value[0, 40] unless value.include?("://")
          uri = URI.parse(value)
          "#{uri.scheme}://#{uri.host}"
        rescue URI::InvalidURIError
          nil
        end

        def visit_attrs(data, ua:, visitor:)
          {
            "path" => local_path(data["path"]),
            "referrer" => referrer(data["referrer"]),
            "visitor" => visitor,
            "viewport" => data["viewport"].to_s.match?(/\A\d{2,5}x\d{2,5}\z/) ? data["viewport"] : nil,
            "device" => DEVICES.include?(data["device"]) ? data["device"] : device_from_ua(ua),
            "lcp_ms" => number(data["lcp_ms"], 600_000)&.round,
            "inp_ms" => number(data["inp_ms"], 600_000)&.round,
            "cls" => number(data["cls"], 100)&.round(4),
            "bot" => Subscribers::Requests::BOT_UA.match?(ua)
          }.compact
        end

        private
          # Path only: query strings can carry tokens.
          def local_path(value)
            path = value.to_s.split(/[?#]/).first.to_s
            path.start_with?("/") ? Scrubber.clean_string(path, 512) : nil
          end

          def referrer(value)
            value = value.to_s.split(/[?#]/).first.to_s
            value.empty? ? nil : Scrubber.clean_string(value, 512)
          end

          def number(value, max)
            number = Float(value, exception: false) if value.is_a?(Numeric) || value.is_a?(String)
            number if number&.finite? && number >= 0 && number <= max
          end

          def device_from_ua(ua)
            if ua.match?(/iPad|Tablet|PlayBook|Silk/i) then "tablet"
            elsif ua.match?(/Mobi|iPhone|Android/i) then "phone"
            else "desktop"
            end
          end
      end
  end
end
