module Kulla
  module Subscribers
    # process_action.action_controller -> `request`
    class Requests
      EVENT = "process_action.action_controller".freeze
      SKIP_PATH = %r{\A/(?:up/?\z|assets/|rails/active_storage/|cable(?:/|\z))}
      BOT_UA = /bot\b|crawl|spider|slurp|headless|lighthouse|facebookexternalhit|embedly|preview|monitor|uptime|curl\/|wget\/|python-requests|go-http-client|httpclient|okhttp/i

      START = "start_processing.action_controller".freeze

      def self.subscribe(client)
        ActiveSupport::Notifications.subscribe(START) do |_name, _start, _finish, _id, payload|
          request = payload[:request]
          Context.start(trace: (request.request_id if request.respond_to?(:request_id)),
                        label: [ payload[:controller], payload[:action] ].compact.join("#").then { |l| l.empty? ? nil : l })
        rescue StandardError
          nil
        end
        ActiveSupport::Notifications.subscribe(EVENT) do |event|
          ctx = Context.finish
          track(client, event, ctx)
        end
      end

      def self.track(client, event, ctx = nil)
        Subscribers::Sql.report_n_plus_one(client, ctx)
        return unless client.config.capture?(:requests)
        attrs, trace = attrs_for(event.payload, event.duration)
        return if attrs.nil?
        attrs.merge!(ctx.counters) if ctx

        level = attrs["status"].to_i >= 500 ? :error : :info
        client.track("request", attrs, trace: trace, level: level, scrub: false)
      rescue StandardError => e
        Kulla.log("request subscriber failed: #{e.class}: #{e.message}")
      end

      # Returns [ attrs, trace ], or nil when the path should be skipped.
      def self.attrs_for(payload, duration)
        request = payload[:request]
        raw_path = (request.respond_to?(:path) ? request.path : payload[:path].to_s.split("?").first).to_s
        return if SKIP_PATH.match?(raw_path)

        headers = payload[:headers]
        ua = header(request, headers, "HTTP_USER_AGENT")
        attrs = {
          "method" => payload[:method] || request&.request_method,
          "path" => route_template(request) || raw_path,
          "status" => status(payload),
          "duration_ms" => duration&.round(1),
          "db_ms" => payload[:db_runtime]&.round(1),
          "view_ms" => payload[:view_runtime]&.round(1),
          "controller" => payload[:controller],
          "action" => payload[:action],
          "ip" => request.respond_to?(:remote_ip) ? request.remote_ip : header(request, headers, "REMOTE_ADDR"),
          "ua" => ua,
          "country" => header(request, headers, "HTTP_CF_IPCOUNTRY"),
          "bot" => ua ? BOT_UA.match?(ua) : nil
        }.compact
        trace = request.request_id if request.respond_to?(:request_id)
        [ attrs, trace ]
      end

      # Rails 7.1+: "/users/:id(.:format)" -> "/users/:id"
      def self.route_template(request)
        return unless request.respond_to?(:route_uri_pattern)
        pattern = request.route_uri_pattern
        pattern&.sub("(.:format)", "")
      rescue StandardError
        nil
      end

      def self.status(payload)
        return payload[:status].to_i if payload[:status]
        return 500 unless payload[:exception]
        if defined?(ActionDispatch::ExceptionWrapper)
          ActionDispatch::ExceptionWrapper.status_code_for_exception(payload[:exception].first)
        else
          500
        end
      end

      def self.header(request, headers, name)
        value = headers ? headers[name] : request&.get_header(name)
        value.nil? || value.to_s.empty? ? nil : Scrubber.clean_string(value, 512)
      rescue StandardError
        nil
      end
    end
  end
end
