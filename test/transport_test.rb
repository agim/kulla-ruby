require "test_helper"

class TransportTest < Minitest::Test
  include KullaTestHelpers

  def setup
    @sleeps = []
  end

  def transport(adapter, **config)
    Kulla::Transport.new(build_config(**config), adapter: adapter, sleeper: ->(s) { @sleeps << s })
  end

  def events(count)
    count.times.map { |i| { "stream" => "log", "attrs" => { "i" => i } } }
  end

  def test_posts_gzip_ndjson_with_bearer_token
    adapter = FakeAdapter.new
    lost = transport(adapter, endpoint: "https://kulla.example.com/").deliver(events(3))

    assert_equal 0, lost
    post = adapter.posts.first
    assert_equal "https://kulla.example.com/api/v1/events", post[:url].to_s
    assert_equal "Bearer kla_test", post[:headers]["Authorization"]
    assert_equal "application/x-ndjson", post[:headers]["Content-Type"]
    assert_equal "gzip", post[:headers]["Content-Encoding"]

    raw = Zlib.gunzip(post[:body])
    assert_equal 3, raw.count("\n")
    assert raw.end_with?("\n")
    assert_equal [ 0, 1, 2 ], raw.each_line.map { |line| JSON.parse(line)["attrs"]["i"] }
  end

  def test_retries_5xx_with_exponential_backoff
    adapter = FakeAdapter.new(500, 503)
    assert_equal 0, transport(adapter).deliver(events(2))

    assert_equal 3, adapter.posts.size
    assert_equal 2, @sleeps.size
    assert_in_delta 0.55, @sleeps[0], 0.051
    assert_in_delta 1.1, @sleeps[1], 0.101
  end

  def test_retries_network_errors
    adapter = FakeAdapter.new(Errno::ECONNREFUSED.new, Net::OpenTimeout.new)
    assert_equal 0, transport(adapter).deliver(events(1))
    assert_equal 3, adapter.posts.size
  end

  def test_gives_up_after_three_retries
    adapter = FakeAdapter.new(500, 500, 500, 500, 500)
    assert_equal 4, transport(adapter).deliver(events(4))

    assert_equal 4, adapter.posts.size
    assert_equal 3, @sleeps.size
    assert_in_delta 2.2, @sleeps[2], 0.201
  end

  def test_respects_retry_after_on_429
    limited = Kulla::Transport::Response.new(429, { "retry-after" => "7" }, '{"error":"rate limited"}')
    adapter = FakeAdapter.new(limited)
    assert_equal 0, transport(adapter).deliver(events(1))
    assert_equal [ 7.0 ], @sleeps
  end

  def test_retry_after_is_capped
    limited = Kulla::Transport::Response.new(429, { "Retry-After" => "3600" }, "")
    transport(FakeAdapter.new(limited)).deliver(events(1))
    assert_equal [ Kulla::Transport::MAX_DELAY ], @sleeps
  end

  def test_drops_batch_on_other_4xx_without_retrying
    [ 400, 401, 403, 413, 422 ].each do |status|
      adapter = FakeAdapter.new(status)
      assert_equal 2, transport(adapter).deliver(events(2)), status
      assert_equal 1, adapter.posts.size
    end
    assert_empty @sleeps
  end

  def test_zero_retries_for_shutdown
    adapter = FakeAdapter.new(500)
    assert_equal 1, transport(adapter).deliver(events(1), retries: 0)
    assert_equal 1, adapter.posts.size
  end

  def test_splits_by_max_batch
    adapter = FakeAdapter.new
    transport(adapter).deliver(events(5), max_batch: 2)
    assert_equal [ 2, 2, 1 ], adapter.posts.map { |post| KullaTestHelpers.decode(post[:body]).size }
  end

  def test_splits_by_compressed_size_and_drops_single_oversized_events
    noisy = 6.times.map { { "stream" => "log", "attrs" => { "blob" => SecureRandom.hex(1_000) } } }
    adapter = FakeAdapter.new
    lost = transport(adapter).deliver(noisy, max_bytes: 2_500)

    assert_equal 0, lost
    assert_operator adapter.posts.size, :>, 1
    assert adapter.posts.all? { |post| post[:body].bytesize <= 2_500 }
    assert_equal 6, adapter.events.size

    huge = [ { "stream" => "log", "attrs" => { "blob" => SecureRandom.hex(5_000) } } ]
    assert_equal 1, transport(FakeAdapter.new).deliver(huge, max_bytes: 2_500)
  end

  def test_logs_rejections_and_counts_them_as_delivered
    log = StringIO.new
    body = '{"accepted":1,"rejected":[{"index":1,"error":"stream is invalid"}]}'
    adapter = FakeAdapter.new(Kulla::Transport::Response.new(202, {}, body))
    Kulla.config.logger = Logger.new(log)

    assert_equal 0, transport(adapter).deliver(events(2))
    assert_includes log.string, "stream is invalid"
  end

  def test_fetch_manifest_uses_etag
    adapter = FakeAdapter.new(manifest: { "app" => { "code" => "shop" } })
    t = transport(adapter)

    status, manifest, etag = t.fetch_manifest
    assert_equal [ 200, "shop", "W/\"m1\"" ], [ status, manifest["app"]["code"], etag ]

    status, manifest, = t.fetch_manifest(etag)
    assert_equal 304, status
    assert_nil manifest
    assert_equal "W/\"m1\"", adapter.gets.last[:headers]["If-None-Match"]
    assert_equal "https://kulla.example/api/v1", adapter.gets.last[:url].to_s
  end
end
