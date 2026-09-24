require "test_helper"

class ClientTest < Minitest::Test
  include KullaTestHelpers

  def test_track_builds_scrubbed_events
    adapter = FakeAdapter.new
    client = build_client(adapter, filter_parameters: [ :email ])
    client.track("User Signup", { plan: "pro", email: "a@b.c", password: "x" }, level: :warn, message: "hi")
    client.flush

    event = adapter.events.first
    assert_equal "user_signup", event["stream"]
    assert_equal "warn", event["level"]
    assert_equal "hi", event["message"]
    assert_equal({ "plan" => "pro", "email" => "[FILTERED]" }, event["attrs"])
    assert_equal %w[attrs env host level message release stream ts], event.keys.sort
  end

  def test_disabled_client_buffers_nothing
    client = build_client(enabled: false)
    assert_nil client.track("x", {})
    assert_equal 0, client.buffer.size
    refute client.worker_alive?
  end

  def test_enabled_defaults_to_token_and_endpoint_present_and_not_test_env
    config = Kulla::Configuration.new
    config.env = "production"
    config.token = nil
    config.enroll = false
    refute config.enabled?
    config.token = "kla_x"
    refute config.enabled?, "no endpoint, no default"
    config.endpoint = "https://kulla.example"
    assert config.enabled?
    config.env = "test"
    refute config.enabled?
  end

  def test_capture_toggles_merge_with_defaults
    config = Kulla::Configuration.new
    config.capture = { heartbeat: false }
    refute config.capture?(:heartbeat)
    assert config.capture?(:requests)
  end

  def test_overflow_is_reported_as_a_log_event
    adapter = FakeAdapter.new
    client = build_client(adapter, buffer_size: 3)
    5.times { |i| client.track("tick", { i: i }) }
    client.flush

    events = adapter.events
    assert_equal [ 2, 3, 4 ], events.first(3).map { |e| e["attrs"]["i"] }
    loss = events.last
    assert_equal "log", loss["stream"]
    assert_equal "warn", loss["level"]
    assert_equal({ "dropped" => 2 }, loss["attrs"])

    client.track("tick", {})
    client.flush
    assert_equal 5, adapter.events.size, "the drop count is only reported once"
  end

  def test_undelivered_batches_are_counted_and_reported_after_recovery
    adapter = FakeAdapter.new(400)
    client = build_client(adapter)
    2.times { client.track("tick", {}) }
    client.flush

    client.track("tick", {})
    client.flush
    loss = adapter.events.last
    assert_equal({ "dropped" => 0, "unsent" => 2 }, loss["attrs"])
  end

  def test_drop_count_survives_a_failed_delivery
    adapter = FakeAdapter.new(500, 500, 500, 500)
    client = build_client(adapter, buffer_size: 1)
    2.times { client.track("tick", {}) }
    client.flush

    client.flush
    loss = adapter.events.last
    assert_equal "log", loss["stream"]
    assert_equal({ "dropped" => 1, "unsent" => 1 }, loss["attrs"])
  end

  def test_worker_flushes_when_batch_size_is_reached
    adapter = FakeAdapter.new
    client = build_client(adapter, batch_size: 3)
    3.times { client.track("tick", {}) }

    wait_until { adapter.events.size == 3 }
    assert client.worker_alive?
    assert_equal 1, adapter.gets.size, "fetches the manifest when the worker starts"
  end

  def test_manifest_limits_batch_size
    manifest = { "endpoints" => [ { "rel" => "events", "path" => "/api/v1/events", "max_batch" => 2, "max_bytes" => 1_048_576 } ] }
    adapter = FakeAdapter.new(manifest: manifest)
    client = build_client(adapter)
    client.track("tick", {})
    wait_until { client.manifest }
    4.times { client.track("tick", {}) }
    client.flush

    assert_equal [ 2, 2, 1 ], adapter.posts.map { |post| KullaTestHelpers.decode(post[:body]).size }
  end

  def test_after_fork_starts_with_an_empty_buffer
    client = build_client
    client.track("tick", {})
    client.instance_variable_set(:@pid, -1)
    client.after_fork

    assert_equal 0, client.buffer.size
    assert client.worker_alive?
  end

  def test_shutdown_sends_remaining_events_once
    adapter = FakeAdapter.new(500)
    client = build_client(adapter)
    client.track("tick", {})
    client.shutdown

    assert_equal 1, adapter.posts.size
    refute client.worker_alive?
  end

  def test_error_capture
    adapter = FakeAdapter.new
    client = build_client(adapter)
    error = begin
      raise ArgumentError, "bad"
    rescue => e
      e
    end
    client.error(error, context: { order_id: 7, api_token: "t" }, handled: false, severity: :error, source: "test")
    client.flush

    event = adapter.events.first
    assert_equal "error", event["stream"]
    assert_equal "error", event["level"]
    assert_equal "ArgumentError: bad", event["message"]
    attrs = event["attrs"]
    assert_equal "ArgumentError", attrs["class"]
    assert_equal false, attrs["handled"]
    assert_equal "test", attrs["source"]
    assert_equal({ "order_id" => 7 }, attrs["context"])
    assert_match(/\Atest\/client_test\.rb:\d+ in '.+'\z/, attrs["backtrace"].first)
    assert_operator attrs["app_frames"], :>=, 1
    assert_operator attrs["backtrace"].size, :<=, 50
  end

  def test_public_api_never_raises
    Kulla.configure do |c|
      c.token = "kla_test"
      c.env = "production"
      c.logger = nil
      c.transport = Kulla::Transport.new(c, adapter: FakeAdapter.new(RuntimeError.new("boom")), sleeper: ->(_) { })
      c.flush_interval = 3600
    end
    exploding = Object.new
    def exploding.to_s = raise("to_s exploded")

    assert_nil Kulla.track(nil)
    Kulla.track("ok", { weird: exploding, nested: { deep: exploding } })
    Kulla.error(StandardError.new("no backtrace"))
    Kulla.error(nil)
    Kulla.flush
    Kulla.shutdown

    Kulla.client.stub(:track, ->(*) { raise "client broke" }) do
      assert_nil Kulla.track("x", {})
    end
  end

  private
    def wait_until(timeout: 2)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        flunk "timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
    end
end
