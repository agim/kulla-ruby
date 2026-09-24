module Kulla
  # Rack middleware that puts the visit beacon into every HTML page, so no layout needs
  # kulla_beacon_tag. Only a full document gets it: status 200, text/html, a buffered body with
  # </head> (or </body>), not a Turbo Stream, Turbo Frame or XHR response, not already tagged. Uses
  # the page's CSP nonce when the app has one. Off with `c.capture = { beacon: false }` or from Kulla's
  # per-app SDK settings; visits themselves are `capture: { visits: false }`.
  class BeaconInjector
    MARKER = "window.__kulla".freeze
    HEAD = "</head>".freeze
    BODY = "</body>".freeze

    def initialize(app, config: nil)
      @app = app
      @config = config
    end

    def call(env)
      status, headers, body = @app.call(env)
      inject(env, status, headers, body)
    end

    private

    # Only the injection is rescued: an exception in the app passes through untouched.
    def inject(env, status, headers, body)
      return [ status, headers, body ] unless wanted?(env, status, headers)

      parts = body.respond_to?(:to_ary) ? body.to_ary : nil # a streamed body is left alone
      return [ status, headers, body ] if parts.nil?

      html = parts.join
      at = html.index(HEAD) || html.index(BODY)
      if at.nil? || html.include?(MARKER)
        return [ status, headers, parts ]
      end

      html = html.dup.insert(at, tag(env))
      body.close if body.respond_to?(:close)
      set_length(headers, html)
      [ status, headers, [ html ] ]
    rescue StandardError => e
      Kulla.log("beacon injection failed: #{e.class}: #{e.message}")
      [ status, headers, body ]
    end

      def config = @config || Kulla.config

      def wanted?(env, status, headers)
        return false unless status == 200 && config.enabled? && config.capture?(:visits) && config.capture?(:beacon)
        return false unless header(headers, "content-type").to_s.start_with?("text/html")
        return false if env["HTTP_TURBO_FRAME"] || env["HTTP_X_REQUESTED_WITH"].to_s == "XMLHttpRequest"
        return false if env["HTTP_ACCEPT"].to_s.include?("text/vnd.turbo-stream.html")
        env["REQUEST_METHOD"] == "GET"
      end

      def tag(env)
        nonce = env["action_dispatch.content_security_policy_nonce"]
        nonce_attr = nonce ? %( nonce="#{nonce.to_s.gsub('"', "&quot;")}") : ""
        %(<script#{nonce_attr}>#{Helper.beacon_js(VisitEndpoint::PATH)}</script>)
      end

      def header(headers, name)
        headers[name] || headers[name.split("-").map(&:capitalize).join("-")]
      end

      def set_length(headers, html)
        key = headers.key?("content-length") ? "content-length" : (headers.key?("Content-Length") ? "Content-Length" : nil)
        headers[key] = html.bytesize.to_s if key
      end
  end
end
