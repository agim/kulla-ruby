module Kulla
  module Subscribers
    # Rack::Attack notifications -> `security`
    class Security
      EVENTS = %w[blocklist.rack_attack throttle.rack_attack track.rack_attack rack.attack].freeze
      MATCH_TYPES = %w[blocklist throttle track].freeze

      def self.subscribe(client)
        EVENTS.each do |name|
          ActiveSupport::Notifications.subscribe(name) do |event|
            track(client, event)
          end
        end
      end

      def self.track(client, event)
        return unless client.config.capture?(:security)
        attrs = attrs_for(event.payload)
        return if attrs.nil?

        client.track("security", attrs, level: :warn, scrub: false)
      rescue StandardError => e
        Kulla.log("security subscriber failed: #{e.class}: #{e.message}")
      end

      # Rack::Attack 6+ sends { request: req }; 5.x sent the request itself as the payload.
      def self.attrs_for(payload)
        request = payload.is_a?(Hash) ? payload[:request] : payload
        return unless request.respond_to?(:env)

        env = request.env
        match_type = env["rack.attack.match_type"].to_s
        return unless MATCH_TYPES.include?(match_type)

        {
          "rule" => env["rack.attack.matched"]&.to_s,
          "match_type" => match_type,
          "ip" => request.respond_to?(:ip) ? request.ip : env["REMOTE_ADDR"],
          "path" => request.respond_to?(:path) ? request.path : env["PATH_INFO"]
        }.compact
      end
    end
  end
end
