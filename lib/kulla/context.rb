module Kulla
  # What happened during one request or job: query counts (N+1 detection), cache hits, outgoing HTTP
  # calls, and breadcrumbs (the last few things before an error). Execution-local, so threads and
  # fibers don't mix; nested units (a job performed inline in a request) get their own and restore
  # the outer one when they finish.
  class Context
    BREADCRUMBS = 20
    KEY = :kulla_context
    LAST = :kulla_last_context

    attr_reader :trace, :label, :queries, :statements, :cache_hits, :cache_misses, :http_calls, :breadcrumbs, :parent
    attr_accessor :queue_wait_ms

    def self.store
      defined?(ActiveSupport::IsolatedExecutionState) ? ActiveSupport::IsolatedExecutionState : Thread.current
    end

    def self.current = store[KEY]

    def self.start(trace: nil, label: nil)
      store[LAST] = nil
      store[KEY] = new(trace: trace, label: label, parent: current)
    end

    # Ends the current context and returns it (the outer one becomes current again). It stays
    # available as `last` because Rails reports an unhandled error after the request has finished.
    def self.finish
      ctx = current
      store[KEY] = ctx&.parent
      store[LAST] = ctx
      ctx
    end

    def self.last = store[LAST]

    def initialize(trace: nil, label: nil, parent: nil)
      @trace = trace
      @label = label
      @parent = parent
      @queries = 0
      @statements = Hash.new(0)
      @cache_hits = 0
      @cache_misses = 0
      @http_calls = 0
      @breadcrumbs = []
    end

    def query!(normalized)
      @queries += 1
      @statements[normalized] += 1 if normalized
    end

    def cache!(hit) = hit ? @cache_hits += 1 : @cache_misses += 1
    def http! = @http_calls += 1

    def breadcrumb(kind, message, **data)
      @breadcrumbs << { "kind" => kind, "message" => Scrubber.clean_content(message.to_s[0, 300]), "at" => Time.now.utc.iso8601(3) }.merge(data.transform_keys(&:to_s)).compact
      @breadcrumbs.shift while @breadcrumbs.size > BREADCRUMBS
    end

    # Same SELECT run at least `threshold` times: [ [sql, count], ... ].
    def repeated(threshold)
      @statements.select { |sql, n| n >= threshold && sql.start_with?("SELECT") }.sort_by { |_, n| -n }.first(5)
    end

    def counters
      { "queries" => @queries, "cache_hits" => @cache_hits, "cache_misses" => @cache_misses, "http_calls" => @http_calls }
        .reject { |_, v| v.zero? }
    end
  end
end
