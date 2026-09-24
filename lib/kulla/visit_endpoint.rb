module Kulla
  # Rack middleware behind kulla_beacon_tag. The browser posts to the app's own /kulla/visit so the
  # Kulla token never reaches it; this turns the beacon into a `visit` event and answers 204.
  class VisitEndpoint
    PATH = "/kulla/visit".freeze
    MAX_BODY_BYTES = 4_096
    DEVICES = %w[phone tablet desktop].freeze

    def initialize(app, client: nil, secret: nil)
      @app = app
      @client = client
      @secret = secret
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == PATH
      return [ 405, { "allow" => "POST" }, [] ] unless env["REQUEST_METHOD"] == "POST"

      record(env)
      [ 204, {}, [] ]
    end

    private
      def record(env)
        client = @client || Kulla.client
        return unless client.config.enabled? && client.config.capture?(:visits)
        # Browsers mark beacons with Sec-Fetch-Site; ignore anything posted from another site.
        site = env["HTTP_SEC_FETCH_SITE"]
        return if site && !%w[same-origin none].include?(site)

        data = parse(env["rack.input"])
        return if data.nil?

        ua = env["HTTP_USER_AGENT"].to_s
        attrs = self.class.visit_attrs(data, ua: ua, visitor: visitor(ip(env), ua))
        client.track("visit", attrs, scrub: false) if attrs["path"]
      rescue StandardError => e
        Kulla.log("visit endpoint failed: #{e.class}: #{e.message}")
      end

      def parse(input)
        return if input.nil?
        # Rack::MethodOverride may already have read a form-encoded body.
        input.rewind if input.respond_to?(:rewind)
        body = input.read(MAX_BODY_BYTES + 1)
        return if body.nil? || body.bytesize > MAX_BODY_BYTES

        data = JSON.parse(body)
        data.is_a?(Hash) ? data : nil
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
