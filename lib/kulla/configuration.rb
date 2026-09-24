module Kulla
  class Configuration
    ENROLL_CONTEXT = "kulla-enroll-v1".freeze
    BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".freeze
    CAPTURE_DEFAULTS = {
      requests: true, errors: true, jobs: true, mail: true, security: true,
      events: true, deploy: true, heartbeat: true, visits: true
    }.freeze
    # Rails 8.1 re-emits its own instrumentation as structured events once anything subscribes
    # to Rails.event. Kulla already captures those as request/job/mail, so skip them.
    DEFAULT_IGNORED_EVENTS = %w[
      kulla. action_controller. action_dispatch. action_view. action_mailer. action_mailbox.
      action_cable. action_text. active_job. active_record. active_storage. active_support. railties.
    ].freeze

    attr_writer :token, :endpoint, :env, :release, :enabled, :filter_parameters, :host, :logger, :enroll, :app_name
    attr_accessor :flush_interval, :batch_size, :buffer_size, :timeout, :transport, :ignored_events
    # The token Kulla hands out after the owner approves this app (joining without a token). Memory only.
    attr_accessor :issued_token
    # Opt-in signal integrations (Rails), both default off:
    #   suppress_bad_emails — ActionMailer interceptor drops recipients with an active
    #                         email.bounced / email.complaint signal.
    #   block_signal_ips    — Rack middleware answers 403 to IPs with an active ip.blocked signal.
    attr_accessor :suppress_bad_emails, :block_signal_ips
    attr_reader :capture

    def initialize
      @flush_interval = 5
      @batch_size = 500
      @buffer_size = 10_000
      @timeout = 2
      @capture = CAPTURE_DEFAULTS.dup
      @ignored_events = DEFAULT_IGNORED_EVENTS.dup
      @transport = nil
      @suppress_bad_emails = false
      @block_signal_ips = false
    end

    def token
      return @token if defined?(@token)
      @token = presence(rails_credential_token) || presence(ENV["KULLA_TOKEN"])
    end

    # Where Kulla runs. No default: set it in an initializer or KULLA_URL.
    def endpoint
      @endpoint ||= presence(ENV["KULLA_URL"])
    end

    # Joining without a token (README, "Joining without a token"): on by default in a Rails production
    # app that has no token. The app asks Kulla to join and waits until the owner approves it.
    def enroll?
      return !!@enroll unless @enroll.nil?
      token.nil? && rails_app? && env == "production"
    end

    # A stable install key derived from the app's secret_key_base. It only proves which install is asking
    # to join; Kulla never accepts it as a token.
    def enrollment_key
      return @enrollment_key if defined?(@enrollment_key)
      secret = rails_app? && Rails.application.respond_to?(:secret_key_base) ? Rails.application.secret_key_base.to_s : ""
      @enrollment_key = secret.empty? ? nil : "kli_#{base58(OpenSSL::HMAC.digest("SHA256", secret, ENROLL_CONTEXT))}"
    rescue StandardError
      @enrollment_key = nil
    end

    # The bearer token sent to Kulla: the configured token, else the one Kulla issued after approval.
    def auth_token
      token || issued_token
    end

    def enrolling?
      token.nil? && enroll? && !enrollment_key.nil?
    end

    def app_name
      @app_name ||= presence(ENV["KULLA_APP_NAME"]) ||
                    (rails_app? && Rails.application.class.respond_to?(:module_parent_name) && Rails.application.class.module_parent_name) ||
                    File.basename(root)
    end

    def env
      @env ||= (rails_app? && Rails.env.to_s) || presence(ENV["RAILS_ENV"]) || presence(ENV["RACK_ENV"]) || "development"
    end

    def release
      return @release if defined?(@release)
      @release = presence(ENV["KULLA_RELEASE"]) || presence(ENV["REVISION"]) || presence(ENV["GIT_SHA"]) ||
                 revision_file || git_revision
    end

    def host
      @host ||= Socket.gethostname
    rescue StandardError
      @host = "unknown"
    end

    def enabled?
      return !!@enabled unless @enabled.nil?
      (!token.nil? || enrolling?) && !endpoint.nil? && env != "test"
    end
    alias_method :enabled, :enabled?

    def filter_parameters
      return @filter_parameters if defined?(@filter_parameters)
      rails_app? ? Array(Rails.application.config.filter_parameters) : []
    end

    # Accepts a partial hash: `c.capture = { heartbeat: false }` keeps the other toggles on.
    def capture=(toggles)
      @capture = CAPTURE_DEFAULTS.merge(toggles.to_h.transform_keys(&:to_sym))
    end

    def capture?(feature)
      !!@capture[feature.to_sym]
    end

    def logger
      return @logger if defined?(@logger)
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
    end

    def root
      if rails_app? && Rails.respond_to?(:root) && Rails.root
        Rails.root.to_s
      else
        Dir.pwd
      end
    end

    def scrubber
      @scrubber ||= Scrubber.new(filter_parameters)
    end

    # filter_parameters may grow while Rails boots; the Railtie calls this after initialize.
    def reset_scrubber!
      @scrubber = nil
    end

    private
      def rails_app?
        defined?(Rails) && Rails.respond_to?(:application) && !Rails.application.nil?
      end

      def rails_credential_token
        return unless rails_app? && Rails.application.respond_to?(:credentials)
        Rails.application.credentials.dig(:kulla, :token)
      rescue StandardError
        nil
      end

      def revision_file
        path = File.join(root, "REVISION")
        presence(File.read(path).strip) if File.file?(path)
      rescue StandardError
        nil
      end

      def git_revision
        return unless File.exist?(File.join(root, ".git"))
        output = IO.popen([ "git", "rev-parse", "--short", "HEAD" ], chdir: root, err: File::NULL, &:read)
        presence(output.to_s.strip) if $?&.success?
      rescue StandardError
        nil
      end

      def base58(bytes)
        number = bytes.unpack1("H*").to_i(16)
        out = +""
        while number.positive?
          number, rem = number.divmod(58)
          out.prepend(BASE58[rem])
        end
        out
      end

      def presence(value)
        value = value.to_s.strip unless value.nil?
        value.nil? || value.empty? ? nil : value
      end
  end
end
