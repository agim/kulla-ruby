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

  def test_processes_share_one_durable_journal_without_buffer_limit_drops
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
