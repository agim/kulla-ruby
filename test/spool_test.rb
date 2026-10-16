require "test_helper"
require "tmpdir"

class SpoolTest < Minitest::Test
  include KullaTestHelpers

  def setup
    @directory = Dir.mktmpdir("kulla-spool-")
  end

  def teardown
    super
    FileUtils.remove_entry(@directory)
  end

  def event(n)
    { "id" => SecureRandom.uuid, "stream" => "log", "message" => "message #{n}", "attrs" => {} }
  end

  def test_restart_append_and_acknowledgement_preserve_exact_records
    spool = Kulla::Spool.new(@directory)
    first = event(1)
    spool.push(first)
    batch = Kulla::Spool.new(@directory).peek(500)
    assert_equal [first], batch.events
    second = event(2)
    spool.push(second) # Appending during network delivery must survive the ack.
    spool.acknowledge(batch)
    assert_equal [second], Kulla::Spool.new(@directory).peek(500).events
    spool.acknowledge(spool.peek(500))
    assert Kulla::Spool.new(@directory).empty?
    assert_equal 0o700, File.stat(@directory).mode & 0o777
    Dir.children(@directory).each { |name| assert_equal 0o600, File.stat(File.join(@directory, name)).mode & 0o777 }
  end

  def test_processes_share_one_durable_journal_below_the_limit_without_drops
    children = 3.times.map do |worker|
      fork do
        spool = Kulla::Spool.new(@directory)
        400.times { |i| spool.push(event("#{worker}:#{i}")) }
        exit! 0
      end
    end
    children.each { |pid| Process.wait(pid); assert_predicate $?, :success? }
    spool = Kulla::Spool.new(@directory)
    ids = []
    until spool.empty?
      batch = spool.peek(500)
      ids.concat(batch.events.map { |e| e.fetch("id") })
      spool.acknowledge(batch)
    end
    assert_equal 1200, ids.size
    assert_equal 1200, ids.uniq.size
  end

  def test_corrupt_cursor_replays_instead_of_skipping_and_interrupted_tail_is_preserved
    spool = Kulla::Spool.new(@directory)
    first = event(1)
    spool.push(first)
    File.write(File.join(@directory, "cursor.json"), "interrupted")
    assert_equal [first], spool.peek(500).events
    File.open(File.join(@directory, "logs.ndjson"), "a") { |file| file.write('{"interrupted":') }
    assert_equal [first], Kulla::Spool.new(@directory).peek(500).events
    spool.push(event(2))
    assert_equal 2, spool.peek(500).events.size
    assert_equal ['{"interrupted":'], Dir.glob(File.join(@directory, "incomplete-*.ndjson")).map { |path| File.read(path) }
  end

  def test_failed_and_malformed_acknowledgements_keep_records_until_valid_ack
    config = build_config(durable_buffer: true, spool_directory: @directory)
    responses = [503, Kulla::Transport::Response.new(202, {}, '{}'), Kulla::Transport::Response.new(202, {}, '{"accepted":2,"rejected":[]}')]
    adapter = FakeAdapter.new(*responses)
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: adapter))
    2.times { |i| client.buffer.push(event(i)) }
    original = client.buffer.peek(500).events
    2.times { client.flush(retries: 0); assert_equal original, client.buffer.peek(500).events }
    client.flush(retries: 0)
    assert client.buffer.empty?
    assert_equal [original, original, original], adapter.posts.map { |post| KullaTestHelpers.decode(post[:body]) }
  end

  def test_partial_rejection_is_durably_quarantined_before_cursor_advances
    config = build_config(durable_buffer: true, spool_directory: @directory)
    response = Kulla::Transport::Response.new(202, {}, '{"accepted":1,"rejected":[{"index":1,"error":"invalid log"}]}')
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: FakeAdapter.new(response)))
    records = [event(1), event(2)]
    records.each { |record| client.buffer.push(record) }
    client.flush(retries: 0)
    assert client.buffer.empty?
    quarantine = JSON.parse(File.read(File.join(@directory, "rejected.ndjson")))
    assert_equal [records[1]], quarantine.fetch("events")
  end

  def test_production_defaults_and_shutdown_do_not_force_an_early_upload
    config = Kulla::Configuration.new
    assert config.durable_buffer
    assert_equal 900, config.collection_interval
    assert_equal 0, config.logs_per_minute
    refute config.capture?(:heartbeat)
    config.token = "kla_test"
    config.spool_directory = @directory
    adapter = FakeAdapter.new
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: adapter))
    client.buffer.push(event(1))
    client.shutdown
    assert_empty adapter.posts
    assert_equal 1, Kulla::Spool.new(@directory).peek(500).events.size
  end

  def test_collector_captures_info_logs_without_the_old_cap_and_scrubs_before_spooling
    config = build_config(durable_buffer: true, spool_directory: @directory, logs_per_minute: 0, collection_interval: 900)
    adapter = FakeAdapter.new
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: adapter))
    @clients = [client]
    logger = Kulla::Subscribers::Logs.new(client)
    75.times { |i| logger.info("request #{i} password=short-secret") }
    sleep 0.05
    assert_empty adapter.posts, "crossing a batch/log cap must not force an early upload"
    events = client.buffer.peek(500).events
    assert_equal 75, events.size
    assert events.all? { |record| record["level"] == "info" }
    refute_includes File.read(File.join(@directory, "logs.ndjson")), "short-secret"
  end

  def loss(n) = { "stream" => "log", "level" => "warn", "message" => "kulla: #{n} events dropped (spool full)", "attrs" => { "dropped" => n } }

  def test_spool_never_holds_more_than_max_events_and_records_what_it_dropped
    spool = Kulla::Spool.new(@directory, max_events: 1_000, on_drop: ->(n) { loss(n) })
    ids = 1_100.times.map { |i| event(i).tap { |e| spool.push(e) }["id"] }
    assert_operator spool.size, :<=, 1_000
    events = []
    until (batch = spool.peek(500)).events.empty?
      events.concat(batch.events)
      spool.acknowledge(batch)
    end
    losses = events.select { |e| e["message"].to_s.include?("dropped (spool full)") }
    dropped = losses.sum { |e| e.dig("attrs", "dropped") }
    assert_operator losses.size, :>=, 1
    assert_equal 1_100, dropped + events.size - losses.size, "every record is either delivered or counted as dropped"
    assert_equal ids.last(events.size - losses.size), (events - losses).map { |e| e["id"] }, "the oldest records go first"
    assert_equal dropped, spool.take_dropped
  end

  def test_spool_bytes_stay_bounded_when_kulla_is_unreachable
    spool = Kulla::Spool.new(@directory, max_events: 100_000, max_bytes: 262_144, on_drop: ->(n) { loss(n) })
    big = "x" * 2_000
    2_000.times { |i| spool.push(event(i).merge("message" => big)) } # about 4 MB offered
    assert_operator File.size(File.join(@directory, "logs.ndjson")), :<=, 2 * 262_144 + Kulla::Spool::MIN_COMPACT_BYTES
    assert_operator spool.size, :<, 2_000
  end

  def test_journal_is_compacted_while_delivery_keeps_up_with_new_records
    spool = Kulla::Spool.new(@directory)
    message = "y" * 1_000
    spool.push(event(0).merge("message" => message))
    300.times do |i|
      batch = spool.peek(500)
      spool.push(event(i + 1).merge("message" => message)) # a record arrives during every delivery
      spool.acknowledge(batch)
    end
    assert_equal 1, spool.size
    assert_operator File.size(File.join(@directory, "logs.ndjson")), :<, 2 * Kulla::Spool::MIN_COMPACT_BYTES
  end

  def test_push_never_fsyncs_and_sync_does_it_from_the_worker
    spool = Kulla::Spool.new(@directory)
    spool.push(event(0)) # creates the journal header (one fsync, once)
    calls = []
    counter = Module.new { define_method(:fsync) { calls << path rescue calls << :dir; super() } }
    File.prepend(counter)
    begin
      50.times { |i| spool.push(event(i + 1)) }
      assert_empty calls.grep(/logs\.ndjson/), "a request thread must not wait on the disk"
      assert spool.sync
      assert_equal 1, calls.grep(/logs\.ndjson/).size
      refute spool.sync, "nothing new to sync"
    ensure
      counter.send(:remove_method, :fsync)
    end
  end

  def test_records_dropped_during_delivery_do_not_undo_its_acknowledgement
    spool = Kulla::Spool.new(@directory, max_events: 100, on_drop: ->(n) { loss(n) })
    50.times { |i| spool.push(event(i)) }
    batch = spool.peek(20)
    120.times { |i| spool.push(event(100 + i)) } # the spool fills and drops past the batch
    spool.acknowledge(batch)
    remaining = []
    until (b = spool.peek(500)).events.empty?
      remaining.concat(b.events)
      spool.acknowledge(b)
    end
    refute_includes remaining.map { |e| e["id"] }, batch.events.first["id"]
    assert_operator remaining.size, :<=, 100
  end

  def test_rejected_records_rotate_instead_of_growing
    spool = Kulla::Spool.new(@directory)
    records = 3.times.map { |i| event(i).merge("message" => "z" * 400_000) }
    records.each { |record| spool.quarantine([ record ], [ { "error" => "too big" } ]) }
    assert_operator File.size(File.join(@directory, "rejected.ndjson")), :<=, Kulla::Spool::MAX_REJECTED_BYTES
    assert File.exist?(File.join(@directory, "rejected.1.ndjson"))
  end

  def test_client_bounds_the_spool_by_buffer_size_and_spool_max_bytes
    config = build_config(durable_buffer: true, spool_directory: @directory, buffer_size: 200, spool_max_bytes: 1_048_576)
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: FakeAdapter.new))
    250.times { |i| client.buffer.push(event(i)) }
    assert_operator client.buffer.size, :<=, 200
    assert_equal 200, client.buffer.max_events
    assert_equal 1_048_576, client.buffer.max_bytes
    assert client.buffer.peek(500).events.any? { |e| e["message"].to_s.include?("dropped (spool full)") }
  end

  def test_rails_sink_respects_the_app_logger_level
    config = build_config(durable_buffer: true, spool_directory: @directory)
    client = Kulla::Client.new(config)
    [Logger::WARN, Logger::DEBUG].each do |level|
      source = Struct.new(:level, :broadcasts) do
        def broadcast_to(sink) = broadcasts << sink
      end.new(level, [])
      rails = Module.new
      rails.define_singleton_method(:logger) { source }
      Object.stub_const_for_test(:Rails, rails) { Kulla::Subscribers::Logs.install(client) }
      assert_equal level, source.broadcasts.fetch(0).level
      assert_equal level, source.level
    end
  end
end
