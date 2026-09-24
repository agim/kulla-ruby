require "net/http"
require "uri"

module Kulla
  # Talks to the Kulla API: POST /api/v1/events (gzip NDJSON), GET /api/v1 (manifest),
  # GET /api/v1/signals (sync) and POST /api/v1/signals (reports).
  class Transport
    Response = Struct.new(:code, :headers, :body) do
      def header(name)
        value = headers&.find { |key, _| key.to_s.casecmp?(name) }&.last
        value.is_a?(Array) ? value.first : value
      end
    end

    EVENTS_PATH = "/api/v1/events".freeze
    MANIFEST_PATH = "/api/v1".freeze
    SIGNALS_PATH = "/api/v1/signals".freeze
    ENROLL_PATH = "/api/v1/enroll".freeze
    MAX_BATCH = 500
    MAX_BYTES = 1_048_576
    # The server also caps the decompressed body at 5 MB; stay under it with headroom.
    MAX_RAW_BYTES = 4 * 1_048_576
    RETRIES = 3
    BASE_DELAY = 0.5
    MAX_DELAY = 30

    # Net::HTTP, a fresh connection per request so it is safe to share across threads.
    class NetHttpAdapter
      def initialize(timeout)
        @timeout = timeout
      end

      def post(url, body, headers)
        request(url, Net::HTTP::Post.new(url, headers).tap { |req| req.body = body })
      end

      def get(url, headers)
        request(url, Net::HTTP::Get.new(url, headers))
      end

      private
        def request(url, req)
          http = Net::HTTP.new(url.host, url.port)
          http.use_ssl = url.scheme == "https"
          http.open_timeout = @timeout
          http.read_timeout = @timeout
          http.write_timeout = @timeout
          http.ssl_timeout = @timeout if http.use_ssl?
          http.max_retries = 0
          res = http.start { |conn| conn.request(req) }
          Response.new(res.code.to_i, res.each_header.to_h, res.body)
        end
    end

    attr_reader :config, :adapter

    def initialize(config, adapter: nil, sleeper: nil)
      @config = config
      @adapter = adapter || NetHttpAdapter.new(config.timeout)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def self.encode_line(event)
      JSON.generate(event) << "\n"
    end

    def self.gzip(string)
      io = StringIO.new(+"".b)
      writer = Zlib::GzipWriter.new(io)
      writer.write(string)
      writer.close
      io.string
    end

    # Sends events, splitting by count and size. Returns the number of events that were not delivered.
    def deliver(events, retries: RETRIES, path: EVENTS_PATH, max_batch: MAX_BATCH, max_bytes: MAX_BYTES)
      lines = events.filter_map do |event|
        self.class.encode_line(event)
      rescue StandardError => e
        Kulla.log("could not encode #{event["stream"]} event: #{e.class}: #{e.message}")
        nil
      end
      lost = events.size - lines.size

      chunk(lines, max_batch).sum(lost) do |group|
        post_group(group, retries, path, max_bytes)
      end
    end

    # Returns [ status, manifest_or_nil, etag ].
    def fetch_manifest(etag = nil)
      headers = base_headers
      headers["If-None-Match"] = etag if etag
      response = adapter.get(url(MANIFEST_PATH), headers)
      manifest = response.code == 200 ? JSON.parse(response.body.to_s) : nil
      [ response.code, manifest, response.header("ETag") || manifest&.dig("etag") ]
    rescue StandardError => e
      Kulla.log("manifest fetch failed: #{e.class}: #{e.message}")
      [ nil, nil, etag ]
    end

    # GET /api/v1/signals?since=<cursor>. Returns [ status, page_or_nil ]; status is nil on a
    # network error.
    def fetch_signals(path = SIGNALS_PATH, since: nil)
      query = since.nil? || since.to_s.empty? ? "" : "?#{URI.encode_www_form(since: since)}"
      response = adapter.get(url(path + query), base_headers)
      page = response.code == 200 ? JSON.parse(response.body.to_s) : nil
      [ response.code, page.is_a?(Hash) ? page : nil ]
    rescue StandardError => e
      Kulla.log("signals fetch failed: #{e.class}: #{e.message}")
      [ nil, nil ]
    end

    # POST /api/v1/signals with a JSON body. One attempt; returns the status (nil on a network error).
    def report_signal(body, path: SIGNALS_PATH)
      response = adapter.post(url(path), JSON.generate(body), base_headers.merge("Content-Type" => "application/json"))
      response.code
    rescue StandardError => e
      Kulla.log("POST #{path} failed: #{e.class}: #{e.message}")
      nil
    end

    # POST /api/v1/enroll, the only call without a token: ask to join, and pick up the token once the
    # owner has approved this app. Returns [ state, token ]; state is nil on a network or server error.
    def enroll
      body = { key: config.enrollment_key, name: config.app_name, site: config.site, host: config.host, env: config.env, sdk: Kulla::VERSION }
      response = adapter.post(url(ENROLL_PATH), JSON.generate(body.compact),
                              site_header("Accept" => "application/json", "Content-Type" => "application/json", "User-Agent" => "kulla-ruby/#{Kulla::VERSION}"))
      return [ "rejected", nil ] if response.code == 403
      return [ nil, nil ] unless response.code.between?(200, 299)

      data = JSON.parse(response.body.to_s)
      [ data["state"], data["token"] ]
    rescue StandardError => e
      Kulla.log("enroll failed: #{e.class}: #{e.message}")
      [ nil, nil ]
    end

    private
      def chunk(lines, max_batch)
        groups = []
        current = []
        bytes = 0
        lines.each do |line|
          if current.any? && (current.size >= max_batch || bytes + line.bytesize > MAX_RAW_BYTES)
            groups << current
            current = []
            bytes = 0
          end
          current << line
          bytes += line.bytesize
        end
        groups << current if current.any?
        groups
      end

      def post_group(lines, retries, path, max_bytes)
        body = self.class.gzip(lines.join)
        if body.bytesize > max_bytes
          if lines.size == 1
            Kulla.log("dropping one event larger than #{max_bytes} bytes compressed")
            return 1
          end
          half = lines.size / 2
          return post_group(lines[0...half], retries, path, max_bytes) + post_group(lines[half..], retries, path, max_bytes)
        end

        post_with_retries(body, lines.size, retries, path)
      end

      def post_with_retries(body, count, retries, path)
        attempt = 0
        loop do
          response = begin
            adapter.post(url(path), body, event_headers)
          rescue StandardError => e
            Kulla.log("POST #{path} failed: #{e.class}: #{e.message}")
            nil
          end

          code = response&.code
          if code && code.between?(200, 299)
            log_rejections(response)
            return 0
          elsif code && code != 429 && code.between?(400, 499)
            Kulla.log("POST #{path} returned #{code}, dropping #{count} events: #{response.body.to_s[0, 200]}",
                      level: [ 401, 403 ].include?(code) ? :warn : :debug)
            return count
          elsif attempt >= retries
            Kulla.log("giving up on #{count} events after #{attempt + 1} attempts (last status: #{code || "network error"})")
            return count
          end

          @sleeper.call(delay(attempt, response))
          attempt += 1
        end
      end

      # Retry-After when the server sends it (capped), otherwise 0.5s, 1s, 2s... with a little jitter.
      def delay(attempt, response)
        retry_after = parse_retry_after(response&.header("Retry-After"))
        return [ retry_after, MAX_DELAY ].min if retry_after

        base = BASE_DELAY * (2**attempt)
        [ base + rand * base * 0.2, MAX_DELAY ].min
      end

      def parse_retry_after(value)
        return if value.nil? || value.to_s.strip.empty?
        value = value.to_s.strip
        return value.to_f if value.match?(/\A\d+(\.\d+)?\z/)
        [ Time.httpdate(value) - Time.now, 0 ].max
      rescue ArgumentError
        nil
      end

      def log_rejections(response)
        rejected = JSON.parse(response.body.to_s)["rejected"] if response.body && !response.body.empty?
        return if rejected.nil? || rejected.empty?
        Kulla.log("server rejected #{rejected.size} events, e.g. #{rejected.first(3).inspect}")
      rescue StandardError
        nil
      end

      def url(path)
        URI.parse(config.endpoint.to_s.chomp("/") + path)
      end

      def base_headers
        site_header(
          "Authorization" => "Bearer #{config.auth_token}",
          "Accept" => "application/json",
          "User-Agent" => "kulla-ruby/#{Kulla::VERSION}"
        )
      end

      # The app's public hostname rides on every request, so Kulla can name the app by its domain.
      def site_header(headers)
        site = config.site
        site ? headers.merge("X-Kulla-Site" => site) : headers
      end

      def event_headers
        base_headers.merge("Content-Type" => "application/x-ndjson", "Content-Encoding" => "gzip")
      end
  end
end
