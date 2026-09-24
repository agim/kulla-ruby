module Kulla
  module Subscribers
    # perform.active_job -> `job`
    class Jobs
      EVENT = "perform.active_job".freeze

      def self.subscribe(client)
        ActiveSupport::Notifications.subscribe(EVENT) do |event|
          track(client, event)
        end
      end

      def self.track(client, event)
        return unless client.config.capture?(:jobs)
        attrs = attrs_for(event.payload, event.duration)
        return if attrs.nil?

        level = attrs["result"] == "failed" ? :error : :info
        client.track("job", attrs, trace: attrs["job_id"], level: level, scrub: false)
      rescue StandardError => e
        Kulla.log("job subscriber failed: #{e.class}: #{e.message}")
      end

      def self.attrs_for(payload, duration)
        job = payload[:job]
        return if job.nil?

        {
          "class" => job.class.name,
          "queue" => job.respond_to?(:queue_name) ? job.queue_name.to_s : nil,
          "duration_ms" => duration&.round(1),
          "result" => payload[:exception_object] ? "failed" : "ok",
          "attempts" => job.respond_to?(:executions) ? job.executions : nil,
          "job_id" => job.respond_to?(:job_id) ? job.job_id : nil
        }.compact
      end
    end
  end
end
