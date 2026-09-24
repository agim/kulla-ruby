module Kulla
  module Subscribers
    # deliver.action_mailer -> `mail`
    class Mail
      EVENT = "deliver.action_mailer".freeze

      def self.subscribe(client)
        ActiveSupport::Notifications.subscribe(EVENT) do |event|
          track(client, event)
        end
      end

      def self.track(client, event)
        return unless client.config.capture?(:mail)
        attrs = attrs_for(event.payload)
        return if attrs.nil?

        level = attrs["status"] == "failed" ? :error : :info
        client.track("mail", attrs, level: level, scrub: false)
      rescue StandardError => e
        Kulla.log("mail subscriber failed: #{e.class}: #{e.message}")
      end

      # `email` is sent on purpose (bounce handling joins on it) even though many apps list
      # :email in filter_parameters, which is why these attrs skip key filtering.
      def self.attrs_for(payload)
        return if payload[:perform_deliveries] == false

        {
          "status" => payload[:exception_object] || payload[:exception] ? "failed" : "sent",
          "mailer" => payload[:mailer],
          "message_id" => payload[:message_id],
          "email" => Array(payload[:to]).first&.to_s,
          "provider" => provider(payload[:mailer])
        }.compact
      end

      def self.provider(mailer)
        klass = Object.const_get(mailer.to_s) if mailer
        klass.delivery_method.to_s if klass.respond_to?(:delivery_method)
      rescue StandardError
        nil
      end
    end
  end
end
