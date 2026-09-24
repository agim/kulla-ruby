module Kulla
  module Subscribers
    # One `deploy` event per server boot.
    module Deploy
      GEM_LIMIT = 400

      module_function

      def track(client)
        return unless client.config.capture?(:deploy)
        # Deferred to the worker thread: counting pending migrations touches the database.
        client.defer { client.track("deploy", attrs(client.config), scrub: false) }
      end

      def attrs(config)
        {
          "revision" => config.release,
          "ruby" => RUBY_VERSION,
          "rails" => defined?(Rails.version) ? Rails.version : nil,
          "gems" => gems,
          "env_names" => ENV.keys.sort,
          "pending_migrations" => pending_migrations,
          "recurring" => recurring
        }.compact
      end

      def gems
        return {} unless defined?(Bundler)
        Bundler.load.specs.map { |spec| [ spec.name, spec.version.to_s ] }.sort.first(GEM_LIMIT).to_h
      rescue StandardError
        {}
      end

      # Solid Queue's recurring tasks, so Kulla can spot a scheduled job that didn't run.
      def recurring
        return unless defined?(::SolidQueue::RecurringTask)
        tasks = ::SolidQueue::RecurringTask.all.map do |t|
          { "key" => t.key, "class" => t.class_name, "command" => t.command&.first(120), "schedule" => t.schedule }.compact
        end
        tasks.empty? ? nil : tasks.first(100)
      rescue StandardError, ScriptError
        nil
      end

      def pending_migrations
        return unless defined?(ActiveRecord::Base)
        pool = ActiveRecord::Base.connection_pool
        context = pool.respond_to?(:migration_context) ? pool.migration_context : ActiveRecord::Base.connection.migration_context
        context.open.pending_migrations.size
      rescue StandardError, ScriptError
        nil
      end
    end
  end
end
