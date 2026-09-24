module Kulla
  # Rack middleware (opt-in: `c.block_signal_ips = true`) that answers 403 to IPs with an active
  # `ip.blocked` signal. The Railtie inserts it right after ActionDispatch::RemoteIp, so it sees
  # the real client IP and runs before sessions, routing and the app.
  #
  # Apps using rack_attack_abuseipdb with its :kulla provider already block these IPs and don't
  # need this.
  class SignalBlocker
    KIND = "ip.blocked".freeze
    RESPONSE_BODY = "Forbidden\n".freeze

    def initialize(app, client: nil)
      @app = app
      @client = client
    end

    def call(env)
      return @app.call(env) unless blocked?(env)

      [ 403, { "content-type" => "text/plain" }, [ RESPONSE_BODY ] ]
    end

    private
      def blocked?(env)
        client = @client || Kulla.client
        return false unless client.config.block_signal_ips

        ip = (env["action_dispatch.remote_ip"] || env["REMOTE_ADDR"]).to_s
        return false if ip.empty?

        client.signal?(KIND, ip)
      rescue StandardError => e
        Kulla.log("signal blocker failed: #{e.class}: #{e.message}")
        false
      end
  end
end
