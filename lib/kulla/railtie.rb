module Kulla
  class Railtie < Rails::Railtie
    initializer "kulla.visit_endpoint" do |app|
      # Appended, so it runs after ActionDispatch::RemoteIp (and Rack::Attack, if the app uses it).
      app.middleware.use Kulla::VisitEndpoint
      app.middleware.use Kulla::Webhook
      app.middleware.use Kulla::BeaconInjector
    end

    # Opt-in signal integrations. After the app's initializers so `Kulla.configure` has run.
    initializer "kulla.signals", after: :load_config_initializers do |app|
      Kulla::Railtie.install_signal_integrations(app, Kulla.config)
    end

    initializer "kulla.helper" do
      ActiveSupport.on_load(:action_view) { include Kulla::Helper }
    end

    config.after_initialize do
      Kulla::Railtie.boot
    end

    class << self
      def boot
        config = Kulla.config
        config.reset_scrubber!
        return unless config.enabled?

        client = Kulla.client
        install_subscribers(client, config)
        config.process_role ||= "web" if server?
        config.process_role ||= "job" if jobs?
        return if console? || rake?
        # Only a real server or job process asks to join; one-off commands (rails runner, scripts) never do.
        return if config.enrolling? && !(server? || jobs?)

        client.start
        Subscribers::Deploy.track(client) if server?
      rescue StandardError => e
        Kulla.log("boot failed: #{e.class}: #{e.message}")
      end

      # Installed once, for the features enabled at boot. Each subscriber also re-checks its toggle
      # per event, so a feature can still be switched off at runtime.
      def install_subscribers(client, config)
        return if @installed
        @installed = true

        Subscribers::Errors.subscribe(client) if config.capture?(:errors)
        Subscribers::Requests.subscribe(client) if config.capture?(:requests)
        Subscribers::Jobs.subscribe(client) if config.capture?(:jobs)
        Subscribers::Mail.subscribe(client) if config.capture?(:mail)
        Subscribers::Security.subscribe(client) if config.capture?(:security)
        Subscribers::Events.subscribe(client) if config.capture?(:events)
        # Always installed: each checks its toggle per event, so Kulla can switch them on remotely.
        Subscribers::Sql.subscribe(client)
        Subscribers::Cache.subscribe(client)
        Subscribers::RateLimits.subscribe(client)
        Subscribers::Http.install
        Subscribers::Llm.install
        Subscribers::Logs.install(client)
      end

      def install_signal_integrations(app, config)
        if config.block_signal_ips
          if defined?(ActionDispatch::RemoteIp)
            app.middleware.insert_after ActionDispatch::RemoteIp, Kulla::SignalBlocker
          else
            app.middleware.insert_before 0, Kulla::SignalBlocker
          end
        end

        if config.suppress_bad_emails
          ActiveSupport.on_load(:action_mailer) { register_interceptor(Kulla::MailInterceptor) }
        end
      rescue StandardError => e
        Kulla.log("signal integrations failed: #{e.class}: #{e.message}")
      end

      SERVER_PROGRAM = /puma|unicorn|passenger|falcon|pitchfork|thrust|iodine/

      # A web server is running this process: `rails server`, or a server binary (bundle exec puma,
      # thrust). Not a constant that merely exists because the server gem is loaded (Puma::Launcher is
      # defined in any process that requires puma, `rails runner` included).
      def server?
        return false if runner?
        return true if defined?(::Rails::Server)
        [ $PROGRAM_NAME, $0 ].any? { |name| File.basename(name.to_s).match?(SERVER_PROGRAM) || name.to_s.match?(/\Apuma /) }
      end

      def runner?
        defined?(::Rails::Command::RunnerCommand) ? true : false
      end

      def jobs?
        return false if runner?
        [ $PROGRAM_NAME, $0 ].any? { |name| name.to_s.match?(%r{sidekiq|good_job|solid.?queue|(?:\A|/)jobs\z}) }
      end

      def console?
        defined?(::Rails::Console) ? true : false
      end

      def rake?
        defined?(::Rake.application) && ::Rake.application.top_level_tasks.any? ? true : false
      rescue StandardError
        false
      end
    end
  end
end
