module Kulla
  module Subscribers
    # sql.active_record -> per-request query counts (N+1 detection), `query` events for slow statements,
    # and per-table insert counts (`activity`: signups, orders… without any code in the app).
    # SQL is normalized first: literals become ?, so no values leave the app.
    module Sql
      EVENT = "sql.active_record".freeze
      SKIP_NAMES = %w[SCHEMA CACHE EXPLAIN TRANSACTION].freeze
      INTERNAL = /\A(?:SolidQueue|SolidCache|SolidCable)::|\AActiveRecord::(?:SchemaMigration|InternalMetadata)/
      INSERT = /\AINSERT INTO\s+[`"]?(\w+)[`"]?/i
      QUIET_TABLES = /\A(?:solid_|schema_migrations\z|ar_internal_metadata\z|sessions\z)/
      MAX_SQL = 1_000

      module_function

      def subscribe(client)
        ActiveSupport::Notifications.subscribe(EVENT) { |event| track(client, event) }
      end

      def track(client, event)
        payload = event.payload
        return if payload[:cached] || SKIP_NAMES.include?(payload[:name]) || payload[:name].to_s.match?(INTERNAL)

        config = client.config
        sql = normalize(payload[:sql])
        ctx = Context.current
        if ctx
          ctx.query!(sql)
          ctx.breadcrumb("sql", sql[0, 200], duration_ms: event.duration.round(1))
        end

        if config.capture?(:activity) && (table = payload[:sql].to_s[INSERT, 1]) && !table.match?(QUIET_TABLES)
          client.count_activity(table)
        end

        return unless config.capture?(:queries) && event.duration >= config.slow_query_ms
        attrs = { "kind" => "slow", "sql" => sql, "duration_ms" => event.duration.round(1), "name" => payload[:name], "where" => ctx&.label }.compact
        client.track("query", attrs, trace: ctx&.trace, level: :warn, scrub: false)
      rescue StandardError => e
        Kulla.log("sql subscriber failed: #{e.class}: #{e.message}")
      end

      # Reports repeated SELECTs at the end of a request or job.
      def report_n_plus_one(client, ctx)
        return unless ctx && client.config.capture?(:queries)
        ctx.repeated(client.config.n_plus_one).each do |sql, count|
          client.track("query", { "kind" => "n_plus_one", "sql" => sql, "count" => count, "where" => ctx.label }.compact,
                       trace: ctx.trace, level: :warn, scrub: false)
        end
      end

      def normalize(sql)
        sql.to_s
           .gsub(/'(?:[^']|'')*'/, "?")
           .gsub(/\$\d+/, "?")
           .gsub(/\b\d+(?:\.\d+)?\b/, "?")
           .gsub(/\(\s*\?(?:\s*,\s*\?)+\s*\)/, "(?)")
           .gsub(/\s+/, " ").strip[0, MAX_SQL]
      end
    end

    # cache_read.active_support -> hit/miss counts on the current request or job.
    module Cache
      EVENT = "cache_read.active_support".freeze

      module_function

      def subscribe(client)
        ActiveSupport::Notifications.subscribe(EVENT) do |_name, _start, _finish, _id, payload|
          next unless client.config.capture?(:cache) && (ctx = Context.current)
          ctx.cache!(payload[:hit])
        rescue StandardError
          nil
        end
      end
    end

    # rate_limit.action_controller (Rails 8) -> `security` rule "rate_limit".
    module RateLimits
      EVENT = "rate_limit.action_controller".freeze

      module_function

      def subscribe(client)
        ActiveSupport::Notifications.subscribe(EVENT) do |_name, _start, _finish, _id, payload|
          next unless client.config.capture?(:security)
          request = payload[:request]
          attrs = { "rule" => "rate_limit", "match_type" => "throttle",
                    "ip" => request.respond_to?(:remote_ip) ? request.remote_ip : nil,
                    "path" => request.respond_to?(:path) ? request.path : nil,
                    "limit" => payload[:count], "within" => payload[:within]&.to_i }.compact
          client.track("security", attrs, level: :warn, scrub: false)
        rescue StandardError => e
          Kulla.log("rate limit subscriber failed: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
