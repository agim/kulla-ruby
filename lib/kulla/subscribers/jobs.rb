module Kulla
  module Subscribers
    # perform.active_job -> `job`
    class Jobs
      EVENT = "perform.active_job".freeze

      START = "perform_start.active_job".freeze

      def self.subscribe(client)
        ActiveSupport::Notifications.subscribe(START) do |_name, _start, _finish, _id, payload|
          job = payload[:job]
          ctx = Context.start(trace: (job.job_id if job.respond_to?(:job_id)), label: job&.class&.name)
          ctx.queue_wait_ms = queue_wait_ms(job)
        rescue StandardError
          nil
        end
        ActiveSupport::Notifications.subscribe(EVENT) do |event|
          ctx = Context.finish
          track(client, event, ctx)
        end
      end

      # Time between enqueue and start (ActiveJob 7.1+ records enqueued_at).
      def self.queue_wait_ms(job)
        at = job.respond_to?(:enqueued_at) ? job.enqueued_at : nil
        at = Time.iso8601(at) if at.is_a?(String)
        at ? [ ((Time.now - at) * 1000).round, 0 ].max : nil
      rescue StandardError
        nil
      end

      def self.track(client, event, ctx = nil)
        Subscribers::Sql.report_n_plus_one(client, ctx)
        return unless client.config.capture?(:jobs)
        attrs = attrs_for(event.payload, event.duration)
        return if attrs.nil?
        if ctx
          attrs.merge!(ctx.counters)
          attrs["queue_wait_ms"] = ctx.queue_wait_ms if ctx.queue_wait_ms
        end

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
