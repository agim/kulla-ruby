module Kulla
  # Rack middleware behind the app's signal webhook (Kulla › App › Settings › Signal webhook): Kulla
  # POSTs here when a signal changes; the SDK verifies the signature and syncs signals right away
  # instead of at the next poll. Mounted by the Railtie at /kulla/signals. Nothing to configure: the
  # signing key is derived from the app's token (Kulla derives the same from the token's digest), so
  # it exists in every process that holds the token and follows the token when it rotates. Without a
  # token yet (still waiting for approval) the endpoint answers 404.
  class Webhook
    PATH = "/kulla/signals".freeze
    TOLERANCE = 300
    MAX_BODY = 65_536
    CONTEXT = "kulla-webhook-v1".freeze

    def initialize(app, client: nil, key: nil)
      @app = app
      @client = client
      @key = key
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == PATH

      handle(env)
    end

    private

    # Only the webhook itself is rescued: an exception in the app passes through untouched.
    def handle(env)
      return [ 405, { "allow" => "POST" }, [] ] unless env["REQUEST_METHOD"] == "POST"

      client = @client || Kulla.client
      key = @key || self.class.key_for(client.config.auth_token)
      return [ 404, {}, [] ] if key.nil?

      body = env["rack.input"]&.read(MAX_BODY + 1).to_s
      return [ 413, {}, [] ] if body.bytesize > MAX_BODY
      return [ 401, {}, [] ] unless self.class.valid?(key, body, env["HTTP_X_KULLA_SIGNATURE"])

      client.sync_now if client.config.enabled?
      [ 204, {}, [] ]
    rescue StandardError => e
      Kulla.log("webhook failed: #{e.class}: #{e.message}")
      [ 204, {}, [] ]
    end

    public

    # HMAC(SHA-256 of the token, context): the key Kulla signs with for this token.
    def self.key_for(token)
      return if token.nil? || token.to_s.empty?
      OpenSSL::HMAC.hexdigest("SHA256", Digest::SHA256.hexdigest(token.to_s), CONTEXT)
    end

    # "t=<unix>,v1=<hex>[,v1=<hex>…]" (one per active token of the app): HMAC-SHA256 of "<t>.<body>".
    def self.valid?(key, body, header, now: Time.now)
      parts = header.to_s.split(",").map { |kv| kv.split("=", 2) }
      t = parts.find { |k, _| k == "t" }&.last.to_i
      return false if t.zero? || (now.to_i - t).abs > TOLERANCE

      expected = OpenSSL::HMAC.hexdigest("SHA256", key, "#{t}.#{body}")
      parts.any? { |k, v| k == "v1" && v.to_s.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(expected, v.to_s) }
    end
  end
end
