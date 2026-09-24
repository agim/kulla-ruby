require "net/http"

module Kulla
  module Subscribers
    # Outgoing HTTP (Net::HTTP, so Faraday's default adapter too) -> `http`: host, method, path (no query),
    # status, duration. Calls to Kulla itself are skipped.
    module Http
      KEY = :kulla_http_in_flight

      module Patch
        def request(req, body = nil, &block)
          return super if Thread.current[KEY] || Http.skip?(address)

          Thread.current[KEY] = true
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            response = super
            Http.record(self, req, response, started, nil)
            response
          rescue StandardError, Timeout::Error => e
            Http.record(self, req, nil, started, e)
            raise
          ensure
            Thread.current[KEY] = nil
          end
        end
      end

      module_function

      def install
        Net::HTTP.prepend(Patch) unless Net::HTTP.ancestors.include?(Patch)
      end

      def skip?(address)
        client = Kulla.instance_variable_get(:@client)
        return true unless client&.config&.enabled? && client.config.capture?(:http)
        kulla = URI.parse(client.config.endpoint.to_s).host rescue nil
        address.to_s == kulla
      end

      def record(http, req, response, started, error)
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        attrs = { "host" => http.address, "method" => req.method, "path" => req.path.to_s.split("?").first.to_s[0, 200],
                  "status" => response&.code&.to_i, "duration_ms" => ms, "error" => error&.class&.name }.compact
        ctx = Context.current
        if ctx
          ctx.http!
          ctx.breadcrumb("http", "#{attrs["method"]} #{attrs["host"]}#{attrs["path"]} → #{attrs["status"] || attrs["error"]}", duration_ms: ms)
        end
        level = error || attrs["status"].to_i >= 500 ? :warn : :info
        Kulla.client.track("http", attrs, trace: ctx&.trace, level: level, scrub: false)
      rescue StandardError => e
        Kulla.log("http capture failed: #{e.class}: #{e.message}")
      end
    end
  end
end
