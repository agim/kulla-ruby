require "logger"

module Kulla
  module Subscribers
    # Warn/error/fatal log lines -> `log` events (at most logs_per_minute per process) and breadcrumbs.
    # Broadcast from Rails.logger, so the app's own logging is untouched.
    class Logs < ::Logger
      KEY = :kulla_logging

      def self.install(client)
        return unless defined?(Rails) && Rails.logger.respond_to?(:broadcast_to)
        return if Rails.logger.respond_to?(:broadcasts) && Rails.logger.broadcasts.any? { |l| l.is_a?(self) }
        Rails.logger.broadcast_to(new(client))
      end

      def initialize(client)
        super(nil)
        @client = client
        self.level = ::Logger::WARN
        @window = nil
        @sent = 0
      end

      def add(severity, message = nil, progname = nil)
        return true if severity < level || Thread.current[KEY]
        message = (message || (block_given? ? yield : progname)).to_s.strip
        return true if message.empty? || message.start_with?("[kulla]")

        Thread.current[KEY] = true
        level_name = %w[debug info warn error fatal fatal][severity] || "warn"
        Context.current&.breadcrumb("log", message, level: level_name)
        send_event(level_name, message) if @client.config.capture?(:logs)
        true
      rescue StandardError
        true
      ensure
        Thread.current[KEY] = nil
      end

      private

      def send_event(level_name, message)
        minute = Time.now.to_i / 60
        (@window, @sent) = [ minute, 0 ] if @window != minute
        return if @sent >= @client.config.logs_per_minute
        @sent += 1
        @client.track("log", {}, level: level_name, message: message, trace: Context.current&.trace, scrub: true)
      end
    end

    # Any ActiveSupport notification Kulla asks for by name (manifest config "notifications") becomes
    # a stream of that name: scalar payload values plus duration_ms. New data without a gem release.
    module Generic
      @subscribed = {}

      module_function

      def sync(client, names)
        wanted = Array(names).map(&:to_s).grep(/\A[a-z][a-z0-9_]*(\.[a-z0-9_]+)+\z/).first(20)
        (@subscribed.keys - wanted).each { |name| ActiveSupport::Notifications.unsubscribe(@subscribed.delete(name)) }
        (wanted - @subscribed.keys).each do |name|
          @subscribed[name] = ActiveSupport::Notifications.subscribe(name) { |event| track(client, name, event) }
        end
      end

      def track(client, name, event)
        attrs = event.payload.select { |_, v| v.is_a?(String) || v.is_a?(Numeric) || v == true || v == false || v.is_a?(Symbol) }
                     .first(20).to_h { |k, v| [ k.to_s, v.is_a?(Symbol) ? v.to_s : v ] }
        attrs["duration_ms"] = event.duration.round(1)
        client.track(name, attrs, trace: Context.current&.trace)
      rescue StandardError => e
        Kulla.log("#{name} capture failed: #{e.class}: #{e.message}")
      end
    end
  end
end
