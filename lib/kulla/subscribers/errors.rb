module Kulla
  module Subscribers
    # Rails.error subscriber: every reported exception becomes an `error` event.
    class Errors
      BACKTRACE_LIMIT = 50

      def self.subscribe(client)
        return unless defined?(Rails) && Rails.respond_to?(:error)
        Rails.error.subscribe(new(client))
      end

      # Returns [ attrs, trace ]. Context is scrubbed here because the rest of the attrs are
      # SDK-built and sent with scrub: false.
      def self.attrs_for(exception, context:, handled:, severity:, source:, config:)
        context = context.is_a?(Hash) ? context.dup : {}
        extracted, trace = extract_execution_context(context)
        root = config.root
        frames = backtrace(exception, root)

        attrs = {
          "class" => exception.class.name,
          "message" => Scrubber.clean_string(exception.message.to_s, Event::MAX_MESSAGE_BYTES),
          "backtrace" => frames,
          "app_frames" => frames.count { |frame| app_frame?(frame) },
          "handled" => handled ? true : false,
          "severity" => severity.to_s,
          "source" => source&.to_s,
          "context" => config.scrubber.call(extracted.merge(context)),
          "breadcrumbs" => (Context.current || Context.last)&.breadcrumbs&.dup.then { |b| b.nil? || b.empty? ? nil : b }
        }.compact
        [ attrs, trace ]
      end

      # "file:line in 'method'", with paths under the app root made relative so fingerprints
      # survive deploys to new release directories.
      def self.backtrace(exception, root)
        prefix = root.to_s.chomp("/") + "/"
        locations = exception.backtrace_locations
        lines =
          if locations
            locations.first(BACKTRACE_LIMIT).map { |loc| "#{loc.path}:#{loc.lineno} in '#{loc.label}'" }
          else
            Array(exception.backtrace).first(BACKTRACE_LIMIT).map { |line| line.to_s.sub(/:in [`']/, " in '").tr("`", "'") }
          end
        lines.map { |line| line.start_with?(prefix) ? line.delete_prefix(prefix) : line }
      end

      # Relative frames are under the app root; vendored gems don't count.
      def self.app_frame?(frame)
        !frame.start_with?("/", "<") && !frame.start_with?("vendor/")
      end

      # Rails puts the running controller/job into ActiveSupport::ExecutionContext. Replace those
      # objects with a few useful fields instead of serializing them.
      def self.extract_execution_context(context)
        extracted = {}
        trace = nil

        if (controller = context.delete(:controller))
          extracted["controller"] = controller.class.name
          extracted["action"] = controller.action_name if controller.respond_to?(:action_name)
          if controller.respond_to?(:request) && (request = controller.request)
            trace = request.request_id if request.respond_to?(:request_id)
            extracted["path"] = request.path if request.respond_to?(:path)
            extracted["method"] = request.request_method if request.respond_to?(:request_method)
            if request.respond_to?(:filtered_parameters)
              params = request.filtered_parameters.except("controller", "action", "format")
              extracted["params"] = params unless params.empty?
            end
          end
        end

        if (job = context.delete(:job))
          extracted["job_class"] = job.class.name
          extracted["job_id"] = job.job_id if job.respond_to?(:job_id)
          extracted["queue"] = job.queue_name if job.respond_to?(:queue_name)
          extracted["attempts"] = job.executions if job.respond_to?(:executions)
          trace ||= extracted["job_id"]
        end

        user_id = current_user_id
        extracted["user_id"] = user_id if user_id
        [ extracted, trace ]
      rescue StandardError
        [ extracted || {}, trace ]
      end

      # Only the id, never the email.
      def self.current_user_id
        return unless defined?(::Current) && ::Current.respond_to?(:user)
        user = ::Current.user
        user.id if user.respond_to?(:id)
      rescue StandardError
        nil
      end

      def initialize(client)
        @client = client
      end

      def report(error, handled: true, severity: :error, context: {}, source: nil, **)
        return unless @client.config.capture?(:errors)
        @client.error(error, context: context, handled: handled, severity: severity, source: source)
      rescue StandardError => e
        Kulla.log("error subscriber failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
