module Kulla
  # Owns the buffer and the background thread that flushes it. The same thread polls signals and
  # sends signal reports.
  class Client
    HEARTBEAT_INTERVAL = 60
    MANIFEST_INTERVAL = 3600
    SIGNALS_INTERVAL = 60
    ENROLL_INTERVAL = 60
    REJECTED_ENROLL_INTERVAL = 3600
    SHUTDOWN_DEADLINE = 5
    MAX_SIGNAL_PAGES = 100
    MAX_PENDING_REPORTS = 1_000
    REPORT_ATTEMPTS = 3

    attr_reader :config, :buffer, :transport, :manifest, :signals

    def initialize(config, transport: nil)
      @config = config
      @transport = transport || config.transport || Transport.new(config)
      @buffer = Buffer.new(config.buffer_size)
      @lock = Mutex.new
      @flush_lock = Mutex.new
      @wakeup = ConditionVariable.new
      @deferred = []
      @dropped = 0
      @unsent = 0
      @pid = Process.pid
      @thread = nil
      @stopped = false
      @manifest = nil
      @manifest_etag = nil
      @warned_version = false
      @signals = SignalStore.new
      @reports = []
      @reports_retry_at = 0.0
      @approved = !config.enrolling?
      @activity = Hash.new(0)
    end

    # One insert into a table (Subscribers::Sql); sent as per-table counts with the heartbeat.
    def count_activity(table)
      @lock.synchronize { @activity[table] += 1 }
    end

    # False while the app waits for the owner to approve it in Kulla (joining without a token).
    def approved? = @approved

    # scrub: false is for SDK-built attrs with fixed keys; anything user-supplied must be scrubbed.
    def track(stream, attrs = {}, level: :info, message: nil, trace: nil, ts: nil, scrub: true)
      return unless config.enabled?

      attrs = config.scrubber.call(attrs || {}, filter: scrub)
      event = Event.build(stream, attrs, config: config, level: level, message: message, trace: trace, ts: ts)
      if event.nil?
        Kulla.log("ignored event with unusable stream name #{stream.inspect}")
        return
      end
      push(event)
    rescue StandardError => e
      Kulla.log("track failed: #{e.class}: #{e.message}")
      nil
    end

    def error(exception, context: {}, handled: true, severity: :error, source: nil)
      return unless config.enabled?

      attrs, trace = Subscribers::Errors.attrs_for(exception, context: context, handled: handled,
                                                   severity: severity, source: source, config: config)
      level = handled ? Event.normalize_level(severity) : "error"
      track("error", attrs, level: level, message: "#{exception.class}: #{attrs["message"]}", trace: trace, scrub: false)
    rescue StandardError => e
      Kulla.log("error capture failed: #{e.class}: #{e.message}")
      nil
    end

    # True when Kulla has an active signal of this kind for the subject (see SignalStore).
    def signal?(kind, subject)
      return false unless config.enabled?

      ensure_worker
      signals.active?(kind, subject)
    rescue StandardError => e
      Kulla.log("signal? failed: #{e.class}: #{e.message}")
      false
    end

    # Queues POST /api/v1/signals for the worker. Returns true when queued.
    def report_signal(kind, subject, reason: nil, details: {})
      return false unless config.enabled?

      kind = kind.to_s.strip
      subject = subject.to_s.strip
      return false if kind.empty? || subject.empty?

      body = { "kind" => kind, "subject" => Scrubber.clean_string(subject, 512) }
      body["reason"] = Scrubber.clean_string(reason, 200) unless reason.nil? || reason.to_s.empty?
      details = config.scrubber.call(details || {})
      body["details"] = details unless details.empty?

      @lock.synchronize do
        if @reports.size >= MAX_PENDING_REPORTS
          @reports.shift
          Kulla.log("signal report queue full; dropped the oldest report")
        end
        @reports << { body: body, attempts: 0 }
      end
      ensure_worker
      wake
      true
    rescue StandardError => e
      Kulla.log("report_signal failed: #{e.class}: #{e.message}")
      false
    end

    def pending_reports
      @lock.synchronize { @reports.size }
    end

    # One sync pass: every page of GET /api/v1/signals since the cursor. Only when the manifest
    # lists the signals endpoint (the token has signals:read). Runs on the worker thread.
    def sync_signals
      endpoint = manifest_endpoint("signals")
      return false unless endpoint

      path = endpoint["path"] || Transport::SIGNALS_PATH
      MAX_SIGNAL_PAGES.times do
        since = signals.cursor
        status, page = transport.fetch_signals(path, since: since)
        unless status == 200 && page
          Kulla.log("signals sync returned #{status || "a network error"}", level: [ 401, 403 ].include?(status) ? :warn : :debug)
          return false
        end

        signals.apply_page(page)
        break unless page["more"] == true && signals.cursor != since
      end
      true
    rescue StandardError => e
      Kulla.log("signals sync failed: #{e.class}: #{e.message}")
      false
    end

    # Sends queued signal reports. On a network error, 429 or 5xx it stops and retries after
    # flush_interval (up to REPORT_ATTEMPTS per report); other 4xx drop the report.
    def send_signal_reports
      path = report_path
      loop do
        report = @lock.synchronize { @reports.shift }
        break unless report

        if path.nil?
          Kulla.log("dropping signal report: the manifest lists no report endpoint (token lacks signals:write)")
          next
        end

        code = transport.report_signal(report[:body], path: path)
        next if code&.between?(200, 299)

        if code && code != 429 && code.between?(400, 499)
          Kulla.log("signal report returned #{code}, dropping it", level: [ 401, 403 ].include?(code) ? :warn : :debug)
          next
        end

        report[:attempts] += 1
        if report[:attempts] >= REPORT_ATTEMPTS
          Kulla.log("giving up on a signal report after #{report[:attempts]} attempts (last status: #{code || "network error"})")
          next
        end

        @lock.synchronize do
          @reports.unshift(report)
          @reports_retry_at = monotonic + [ config.flush_interval.to_f, 1.0 ].max
        end
        break
      end
    rescue StandardError => e
      Kulla.log("sending signal reports failed: #{e.class}: #{e.message}")
    end

    def push(event)
      ensure_worker
      size = buffer.push(event)
      wake if size >= config.batch_size
      event
    end

    # A signals sync as soon as the worker wakes (the webhook asks for this).
    def sync_now = defer { sync_signals }

    # Runs a block on the worker thread (used for boot work that may touch the database).
    def defer(&block)
      return unless config.enabled?

      @lock.synchronize { @deferred << block }
      ensure_worker
      wake
    end

    # Sends everything buffered right now, on the calling thread.
    def flush(retries: Transport::RETRIES, deadline: nil)
      @flush_lock.synchronize do
        loop do
          batch, dropped, unsent = next_batch
          break if batch.empty?

          lost = transport.deliver(batch, retries: retries, **events_endpoint)
          settle_losses(lost, dropped, unsent)
          # A failed delivery means Kulla is down or refusing; wait for the next interval.
          break if lost.positive? || (deadline && monotonic > deadline)
        end
      end
    end

    def start
      ensure_worker
    end

    # Stops the worker and makes one short attempt to send what is left.
    def shutdown
      stop
      return unless config.enabled? && @approved

      flush(retries: 0, deadline: monotonic + SHUTDOWN_DEADLINE)
      send_signal_reports
    end

    def stop
      thread = nil
      @lock.synchronize do
        @stopped = true
        thread = @thread
        @wakeup.broadcast
      end
      thread&.join(1) unless thread == Thread.current
    end

    # The child of a fork inherits the parent's buffer but not its thread. Start clean.
    def after_fork
      return if @pid == Process.pid

      had_worker = !@thread.nil?
      @pid = Process.pid
      @lock = Mutex.new
      @flush_lock = Mutex.new
      @wakeup = ConditionVariable.new
      @buffer = Buffer.new(config.buffer_size)
      @deferred = []
      @reports = []
      @reports_retry_at = 0.0
      @dropped = 0
      @unsent = 0
      @thread = nil
      ensure_worker if had_worker && config.enabled? && !@stopped
    end

    def worker_alive?
      !!@thread&.alive?
    end

    private
      def ensure_worker
        after_fork if @pid != Process.pid
        return if @thread&.alive? || @stopped

        @lock.synchronize do
          return if @thread&.alive? || @stopped
          @thread = Thread.new { run }
          @thread.name = "kulla" if @thread.respond_to?(:name=)
          @thread.report_on_exception = false
          Kulla.register_at_exit
        end
      end

      def wake
        @lock.synchronize { @wakeup.signal }
      end

      def run
        next_heartbeat = monotonic + HEARTBEAT_INTERVAL
        next_manifest = monotonic
        next_signals = monotonic
        loop do
          break if @stopped

          unless @approved
            wait_for_approval
            next
          end

          if monotonic >= next_manifest
            refresh_manifest
            next_manifest = monotonic + MANIFEST_INTERVAL
          end

          if monotonic >= next_signals
            sync_signals
            next_signals = monotonic + SIGNALS_INTERVAL
          end

          @lock.synchronize do
            if !@stopped && @deferred.empty? && !reports_due? && buffer.size < config.batch_size
              timeout = [ config.flush_interval.to_f, next_heartbeat - monotonic, next_signals - monotonic ].min
              @wakeup.wait(@lock, [ timeout, 0.05 ].max)
            end
          end
          break if @stopped

          run_deferred
          send_signal_reports if @lock.synchronize { reports_due? }
          if monotonic >= next_heartbeat
            heartbeat
            next_heartbeat = monotonic + HEARTBEAT_INTERVAL
          end
          flush
        rescue StandardError => e
          Kulla.log("worker iteration failed: #{e.class}: #{e.message}")
          sleep 1
        end
      end

      # Asks Kulla to join until the owner approves; events keep buffering (the oldest are dropped
      # past buffer_size) and go out once approved.
      def wait_for_approval
        state = check_approval
        return if @approved

        deadline = monotonic + (state == "rejected" ? REJECTED_ENROLL_INTERVAL : ENROLL_INTERVAL)
        @lock.synchronize do
          while !@stopped && (left = deadline - monotonic).positive?
            @wakeup.wait(@lock, left)
          end
        end
      end

      # One POST /api/v1/enroll. Returns the state; once approved, keeps the issued token in memory.
      def check_approval
        unless config.site || @told_no_site
          Kulla.log("no site detected, so this app joins as #{config.app_name.inspect}; set the mailer host in production.rb or KULLA_SITE to name it by its domain", level: :warn)
          @told_no_site = true
        end
        state, token = transport.enroll
        state = "pending" if state == "approved" && token.to_s.empty?
        case state
        when "approved"
          config.issued_token = token
          @approved = true
          Kulla.log("approved by Kulla; sending events", level: :info)
        when "pending"
          Kulla.log("waiting for approval in Kulla (Apps, Waiting for approval)", level: :info) unless @told_pending
          @told_pending = true
        when "rejected"
          Kulla.log("Kulla rejected this app; set a token or approve it in Kulla", level: :warn) unless @told_rejected
          @told_rejected = true
        end
        state
      end

      def run_deferred
        jobs = @lock.synchronize { @deferred.slice!(0..) }
        jobs.each do |job|
          job.call
        rescue StandardError => e
          Kulla.log("deferred task failed: #{e.class}: #{e.message}")
        end
      end

      def heartbeat
        flush_activity
        return unless config.capture?(:heartbeat)
        track("heartbeat", Subscribers::Heartbeat.collect(config), scrub: false)
      end

      def flush_activity
        counts = @lock.synchronize { @activity.dup.tap { @activity.clear } }
        counts.first(50).each { |table, n| track("activity", { "table" => table, "inserts" => n }, scrub: false) }
      end

      # Returns [ events, dropped, unsent ]. The loss counters are only cleared once a batch
      # reporting them has been delivered, so an outage doesn't swallow the count.
      def next_batch
        dropped, unsent = @lock.synchronize do
          @dropped += buffer.take_dropped
          [ @dropped, @unsent ]
        end
        losses = dropped.positive? || unsent.positive?

        limit = [ config.batch_size.to_i, events_endpoint[:max_batch] ].min
        limit -= 1 if losses
        batch = buffer.shift([ limit, 1 ].max)
        batch << loss_event(dropped, unsent) if losses
        [ batch, dropped, unsent ]
      end

      def settle_losses(lost, dropped, unsent)
        @lock.synchronize do
          if lost.zero?
            @dropped -= dropped
            @unsent -= unsent
          else
            reported = dropped.positive? || unsent.positive? ? 1 : 0
            @unsent += [ lost - reported, 0 ].max
          end
        end
      end

      def loss_event(dropped, unsent)
        attrs = { "dropped" => dropped }
        attrs["unsent"] = unsent if unsent.positive?
        message = "kulla: #{dropped} events dropped (buffer full)"
        message += ", #{unsent} not delivered" if unsent.positive?
        Event.build("log", attrs, config: config, level: :warn, message: message)
      end

      # Call with @lock held.
      def reports_due?
        @reports.any? && monotonic >= @reports_retry_at
      end

      def manifest_endpoint(rel)
        Array(@manifest&.fetch("endpoints", nil)).find { |e| e.is_a?(Hash) && e["rel"] == rel }
      end

      # The manifest's report path; the default path while no manifest has loaded (the server
      # answers 403 if the token can't report); nil when the manifest says reports aren't allowed.
      def report_path
        return Transport::SIGNALS_PATH if @manifest.nil?
        endpoint = manifest_endpoint("report")
        endpoint && (endpoint["path"] || Transport::SIGNALS_PATH)
      end

      def events_endpoint
        endpoint = manifest_endpoint("events") || {}
        {
          path: endpoint["path"] || Transport::EVENTS_PATH,
          max_batch: [ (endpoint["max_batch"] || Transport::MAX_BATCH).to_i, 1 ].max,
          max_bytes: [ (endpoint["max_bytes"] || Transport::MAX_BYTES).to_i, 1024 ].max
        }
      end

      def refresh_manifest
        status, manifest, etag = transport.fetch_manifest(@manifest_etag)
        case status
        when 200
          @manifest = manifest if manifest.is_a?(Hash)
          @manifest_etag = etag
          apply_remote_config
          check_sdk_version
        when 401, 403
          if config.enrolling?
            # The issued token was revoked: forget it and ask to join again.
            config.issued_token = nil
            @approved = false
            @told_pending = false
            Kulla.log("Kulla no longer accepts this app's token; asking to join again", level: :warn)
          else
            Kulla.log("manifest request returned #{status}; check the Kulla token", level: :warn)
          end
        end
      rescue StandardError => e
        Kulla.log("manifest refresh failed: #{e.class}: #{e.message}")
      end

      # Kulla's per-app settings: capture toggles, thresholds, extra notifications to record.
      def apply_remote_config
        remote = @manifest["config"]
        config.apply_remote(remote)
        Subscribers::Generic.sync(self, config.notifications) if defined?(ActiveSupport::Notifications)
      rescue StandardError => e
        Kulla.log("remote config failed: #{e.class}: #{e.message}")
      end

      # api.md nests versions per language ({"sdk": {"ruby": {...}}}); PLAN.md shows them flat.
      def check_sdk_version
        return if @warned_version
        sdk = @manifest["sdk"].is_a?(Hash) ? @manifest["sdk"] : {}
        min = (sdk["ruby"].is_a?(Hash) ? sdk["ruby"] : sdk)["min"]
        return unless min && Gem::Version.new(Kulla::VERSION) < Gem::Version.new(min)

        @warned_version = true
        Kulla.log("kulla gem #{Kulla::VERSION} is older than the minimum #{min} the server supports", level: :warn)
      rescue ArgumentError
        nil
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
  end
end
