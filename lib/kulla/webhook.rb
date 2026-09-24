module Kulla
  # Rack middleware behind the app's signal webhook (Kulla › App › Settings › Signal webhook): Kulla
  # POSTs here when a signal changes, signed with the shared secret; the SDK verifies it and syncs
  # signals right away instead of at the next poll. Mounted by the Railtie at /kulla/signals. The
  # secret comes from credentials `kulla.webhook_secret` or KULLA_WEBHOOK_SECRET; without one the
  # endpoint answers 404, so pull stays the only path.
  class Webhook
    PATH = "/kulla/signals".freeze
    TOLERANCE = 300
    MAX_BODY = 65_536

    def initialize(app, client: nil, secret: nil)
      @app = app
      @client = client
      @secret = secret
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == PATH

      handle(env)
    end

    private

    # Only the webhook itself is rescued: an exception in the app passes through untouched.
    def handle(env)
      return [ 405, { "allow" => "POST" }, [] ] unless env["REQUEST_METHOD"] == "POST"

      secret = @secret || Kulla.config.webhook_secret
      return [ 404, {}, [] ] if secret.nil?

      body = env["rack.input"]&.read(MAX_BODY + 1).to_s
      return [ 413, {}, [] ] if body.bytesize > MAX_BODY
      return [ 401, {}, [] ] unless self.class.valid?(secret, body, env["HTTP_X_KULLA_SIGNATURE"])

      client = @client || Kulla.client
      client.sync_now if client.config.enabled?
      [ 204, {}, [] ]
    rescue StandardError => e
      Kulla.log("webhook failed: #{e.class}: #{e.message}")
      [ 204, {}, [] ]
    end

    public

    # "t=<unix>,v1=<hex>": HMAC-SHA256 of "<t>.<body>", the same as Kulla's Webhooks module.
    def self.valid?(secret, body, header, now: Time.now)
      parts = header.to_s.split(",").to_h { |kv| kv.split("=", 2) }
      t = parts["t"].to_i
      return false if t.zero? || (now.to_i - t).abs > TOLERANCE

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{t}.#{body}")
      given = parts["v1"].to_s
      expected.bytesize == given.bytesize && OpenSSL.fixed_length_secure_compare(expected, given)
    end
  end
end
