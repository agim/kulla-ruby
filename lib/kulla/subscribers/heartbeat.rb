module Kulla
  module Subscribers
    # Process and infrastructure stats, collected on the worker thread every 60 seconds.
    module Heartbeat
      DISK_CACHE_SECONDS = 600

      @disk = nil
      @disk_checked_at = nil

      module_function

      def collect(config)
        {
          "rss_mb" => rss_mb,
          "threads" => Thread.list.size,
          "db_pool" => db_pool,
          "queue" => queue,
          "puma" => puma,
          "disk_pct" => disk_pct(config.root),
          "load" => load_average
        }.compact
      end

      def rss_mb
        line = File.foreach("/proc/self/status").find { |l| l.start_with?("VmRSS:") }
        (line.split[1].to_i / 1024.0).round(1) if line
      rescue StandardError
        nil
      end

      def db_pool
        return unless defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:connection_pool)
        stat = ActiveRecord::Base.connection_pool.stat
        stat.slice(:size, :connections, :busy, :idle, :dead, :waiting).transform_keys(&:to_s)
      rescue StandardError
        nil
      end

      def queue
        return unless defined?(::SolidQueue::ReadyExecution)
        {
          "ready" => ::SolidQueue::ReadyExecution.count,
          "failed" => ::SolidQueue::FailedExecution.count,
          "scheduled" => ::SolidQueue::ScheduledExecution.count
        }
      rescue StandardError
        nil
      end

      def puma
        return unless defined?(::Puma) && ::Puma.respond_to?(:stats)
        stats = ::Puma.stats
        stats.is_a?(String) ? JSON.parse(stats) : stats
      rescue StandardError
        nil
      end

      def disk_pct(root)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return @disk if @disk_checked_at && now - @disk_checked_at < DISK_CACHE_SECONDS

        @disk_checked_at = now
        output = IO.popen([ "df", "-P", root.to_s ], err: File::NULL, &:read)
        @disk = output.lines[1]&.split&.[](4)&.delete("%")&.to_i
      rescue StandardError
        @disk = nil
      end

      def load_average
        File.read("/proc/loadavg").split.first.to_f
      rescue StandardError
        nil
      end
    end
  end
end
