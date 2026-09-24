$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "kulla"
require "logger"
require "minitest/autorun"
require "minitest/mock"

# Stands in for Net::HTTP. Each queued item is a status code, a Transport::Response, or an
# exception to raise. When the queue is empty it answers 202.
#
# /api/v1/signals has its own queues: `signal_pages` (GET; a Hash is sent as a 200 JSON page,
# anything else as above; empty queue → an empty page echoing `since`) and `report_responses`
# (POST; empty queue → 202). Those requests land in `signal_gets` and `reports`, not `posts`.
class FakeAdapter
  SIGNALS_PATH = "/api/v1/signals".freeze

  attr_reader :posts, :gets, :signal_gets, :reports

  def initialize(*responses, manifest: nil, signal_pages: [], report_responses: [])
    @responses = responses
    @manifest = manifest
    @signal_pages = signal_pages
    @report_responses = report_responses
    @posts = []
    @gets = []
    @signal_gets = []
    @reports = []
    @mutex = Mutex.new
  end

  def post(url, body, headers)
    @mutex.synchronize do
      if url.path == SIGNALS_PATH
        @reports << { url: url, body: JSON.parse(body), headers: headers }
        item = @report_responses.shift
        next Kulla::Transport::Response.new(202, {}, '{"kind":"ip.blocked","state":"proposed"}') if item.nil?
        next respond(item)
      end

      @posts << { url: url, body: body, headers: headers }
      respond(@responses.shift)
    end
  end

  def get(url, headers)
    @mutex.synchronize do
      next signal_page(url, headers) if url.path == SIGNALS_PATH

      @gets << { url: url, headers: headers }
      if @manifest && headers["If-None-Match"] != "W/\"m1\""
        Kulla::Transport::Response.new(200, { "etag" => "W/\"m1\"" }, JSON.generate(@manifest))
      else
        Kulla::Transport::Response.new(304, {}, "")
      end
    end
  end

  def events
    @mutex.synchronize { @posts.flat_map { |post| KullaTestHelpers.decode(post[:body]) } }
  end

  private
    def signal_page(url, headers)
      @signal_gets << { url: url, headers: headers }
      item = @signal_pages.shift
      if item.nil?
        since = URI.decode_www_form(url.query.to_s).to_h["since"] || "0"
        item = { "signals" => [], "cursor" => since, "more" => false }
      end
      item.is_a?(Hash) ? Kulla::Transport::Response.new(200, {}, JSON.generate(item)) : respond(item)
    end

    def respond(item)
      case item
      when nil then Kulla::Transport::Response.new(202, {}, '{"accepted":1,"rejected":[]}')
      when Integer then Kulla::Transport::Response.new(item, {}, "{}")
      when Exception then raise item
      else item
      end
    end
end

module KullaTestHelpers
  def self.decode(body)
    Zlib.gunzip(body).each_line.map { |line| JSON.parse(line) }
  end

  def build_config(**overrides)
    config = Kulla::Configuration.new
    config.token = "kla_test"
    config.endpoint = "https://kulla.example"
    config.env = "production"
    config.host = "test-host"
    config.release = "abc1234"
    config.enabled = true
    config.logger = nil
    config.filter_parameters = []
    config.flush_interval = 3600 # tests flush explicitly
    overrides.each { |key, value| config.public_send("#{key}=", value) }
    config
  end

  SIGNALS_MANIFEST = {
    "endpoints" => [
      { "rel" => "events", "method" => "POST", "path" => "/api/v1/events", "max_batch" => 500, "max_bytes" => 1_048_576 },
      { "rel" => "signals", "method" => "GET", "path" => "/api/v1/signals", "params" => [ "since", "types[]" ] },
      { "rel" => "report", "method" => "POST", "path" => "/api/v1/signals" }
    ]
  }.freeze

  def signal(kind, subject: nil, subject_hash: nil, state: "active", expires_at: nil)
    {
      "kind" => kind, "subject" => subject, "subject_hash" => subject_hash || Digest::SHA256.hexdigest(subject.to_s),
      "state" => state, "action" => "block_request", "expires_at" => expires_at,
      "updated_at" => Time.now.utc.iso8601(6)
    }.compact
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

  def build_client(adapter = FakeAdapter.new, sleeps: [], **overrides)
    config = build_config(**overrides)
    transport = Kulla::Transport.new(config, adapter: adapter, sleeper: ->(seconds) { sleeps << seconds })
    @clients ||= []
    (@clients << Kulla::Client.new(config, transport: transport)).last
  end

  def teardown
    Array(@clients).each(&:stop)
    Kulla.reset!
    super
  end
end

class Object
  # Temporarily defines a top-level constant (core tests never load Rails).
  def self.stub_const_for_test(name, value)
    had = const_defined?(name, false)
    old = const_get(name) if had
    remove_const(name) if had
    const_set(name, value)
    yield
  ensure
    remove_const(name) if const_defined?(name, false)
    const_set(name, old) if had
  end
end
