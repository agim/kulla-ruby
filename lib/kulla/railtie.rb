module Kulla
  class Railtie < Rails::Railtie
    initializer "kulla.visit_endpoint" do |app|
      # Appended, so it runs after ActionDispatch::RemoteIp (and Rack::Attack, if the app uses it).
      app.middleware.use Kulla::VisitEndpoint
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
        return if console? || rake?

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

      def server?
        return true if defined?(::Rails::Server) || defined?(::Puma::Launcher)
        $PROGRAM_NAME.match?(/puma|unicorn|passenger|falcon|pitchfork|thrust|iodine/)
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
