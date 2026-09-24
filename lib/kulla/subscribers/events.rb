module Kulla
  module Subscribers
    # Rails 8.1 structured events (Rails.event.notify) -> a stream named after the event.
    class Events
      def self.subscribe(client)
        return unless defined?(Rails) && Rails.respond_to?(:event)
        subscriber = new(client)
        Rails.event.subscribe(subscriber) { |event| subscriber.wanted?(event) }
        subscriber
      end

      def initialize(client)
        @client = client
      end

      def wanted?(event)
        name = event[:name].to_s
        !name.empty? && @client.config.ignored_events.none? { |prefix| name.start_with?(prefix) }
      rescue StandardError
        false
      end

      def emit(event)
        return unless @client.config.capture?(:events) && wanted?(event)

        attrs, trace = self.class.attrs_for(event)
        @client.track(event[:name], attrs, ts: event[:timestamp], trace: trace)
      rescue StandardError => e
        Kulla.log("event subscriber failed: #{e.class}: #{e.message}")
      end

      # attrs = payload, plus "tags" and "context" (nested, so they can't clobber payload keys).
      def self.attrs_for(event)
        payload = event[:payload]
        attrs =
          if payload.is_a?(Hash) then payload.dup
          elsif payload.respond_to?(:to_h) then payload.to_h
          elsif payload.nil? then {}
          else { "value" => payload.to_s }
          end

        tags = event[:tags]
        context = event[:context]
        attrs["tags"] = tags if tags.is_a?(Hash) && tags.any?
        attrs["context"] = context if context.is_a?(Hash) && context.any?

        trace = context[:request_id] || context["request_id"] || context[:job_id] || context["job_id"] if context.is_a?(Hash)
        [ attrs, trace ]
      end
    end
  end
end
