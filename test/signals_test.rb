require "test_helper"
require "rack/mock"

class SignalStoreTest < Minitest::Test
  include KullaTestHelpers

  def setup
    @store = Kulla::SignalStore.new
  end

  def test_ip_signals_are_matched_on_the_normalized_subject
    @store.apply(signal("ip.blocked", subject: "2001:DB8:0:0::5"))
    @store.apply(signal("ip.blocked", subject: "203.0.113.5"))

    assert @store.active?("ip.blocked", "2001:db8::5")
    assert @store.active?("ip.blocked", " 203.0.113.5 ")
    refute @store.active?("ip.blocked", "203.0.113.6")
    refute @store.active?("ip.blocked", nil)
    refute @store.active?("email.bounced", "203.0.113.5"), "kinds are kept apart"
  end

  def test_email_signals_are_matched_by_hash_of_the_trimmed_lowercased_address
    hash = Digest::SHA256.hexdigest("bob@example.com")
    @store.apply({ "kind" => "email.bounced", "subject_hash" => hash, "state" => "active" })

    assert @store.active?("email.bounced", "  Bob@Example.COM ")
    refute @store.active?("email.bounced", "alice@example.com")
    refute @store.active?("email.complaint", "bob@example.com")
  end

  def test_email_subject_is_never_used_even_if_present
    @store.apply({ "kind" => "email.bounced", "subject" => "bob@example.com", "subject_hash" => "not-the-hash", "state" => "active" })
    refute @store.active?("email.bounced", "bob@example.com")
  end

  def test_domain_signals_ignore_case
    @store.apply(signal("domain.disposable", subject: "mailinator.com"))
    assert @store.active?("domain.disposable", "Mailinator.COM")
  end

  def test_revoked_and_dismissed_remove
    @store.apply(signal("ip.blocked", subject: "203.0.113.5"))
    @store.apply(signal("ip.blocked", subject: "203.0.113.6"))
    @store.apply(signal("ip.blocked", subject: "203.0.113.5", state: "revoked"))
    @store.apply(signal("ip.blocked", subject: "203.0.113.6", state: "dismissed"))

    refute @store.active?("ip.blocked", "203.0.113.5")
    refute @store.active?("ip.blocked", "203.0.113.6")
    assert_equal 0, @store.size
  end

  def test_expired_entries_are_not_active
    @store.apply(signal("ip.blocked", subject: "203.0.113.5", expires_at: (Time.now - 1).utc.iso8601))
    refute @store.active?("ip.blocked", "203.0.113.5")

    @store.apply(signal("ip.blocked", subject: "203.0.113.6", expires_at: (Time.now + 30).utc.iso8601))
    assert @store.active?("ip.blocked", "203.0.113.6")
    Time.stub(:now, Time.now + 60) do
      refute @store.active?("ip.blocked", "203.0.113.6"), "expiry is honoured locally; the feed doesn't announce it"
    end
  end

  def test_apply_page_moves_the_cursor_and_ignores_junk
    applied = @store.apply_page({ "signals" => [ signal("ip.blocked", subject: "203.0.113.5"), "junk", { "kind" => "ip.blocked" } ],
                                  "cursor" => "c1", "more" => false })
    assert_equal 1, applied
    assert_equal "c1", @store.cursor
    @store.apply_page({ "signals" => [], "cursor" => nil })
    assert_equal "c1", @store.cursor
  end

  def test_thread_safe
    threads = 4.times.map do |t|
      Thread.new do
        200.times do |i|
          ip = "10.#{t}.0.#{i % 250}"
          @store.apply(signal("ip.blocked", subject: ip))
          @store.active?("ip.blocked", ip)
          @store.apply(signal("ip.blocked", subject: ip, state: "revoked")) if i.even?
        end
      end
    end
    threads.each(&:join)
    assert_operator @store.size("ip.blocked"), :>, 0
  end
end

class ClientSignalsTest < Minitest::Test
  include KullaTestHelpers

  # Loads the manifest on the test thread and keeps the worker from starting, so the test drives
  # sync_signals / send_signal_reports itself.
  def load_manifest(client)
    client.instance_variable_set(:@stopped, true)
    client.send(:refresh_manifest)
    assert client.manifest
  end

  def test_no_poll_without_a_manifest_listing_signals
    adapter = FakeAdapter.new
    client = build_client(adapter)
    refute client.sync_signals, "no manifest yet"

    adapter = FakeAdapter.new(manifest: { "endpoints" => [ { "rel" => "events", "path" => "/api/v1/events" } ] })
    client = build_client(adapter)
    load_manifest(client)
    refute client.sync_signals, "token without signals:read"
    assert_empty adapter.signal_gets
  end

  def test_sync_follows_more_and_keeps_the_cursor
    pages = [
      { "signals" => [ signal("ip.blocked", subject: "203.0.113.1") ], "cursor" => "c1", "more" => true },
      { "signals" => [ signal("ip.blocked", subject: "203.0.113.2") ], "cursor" => "c2", "more" => false }
    ]
    adapter = FakeAdapter.new(manifest: SIGNALS_MANIFEST, signal_pages: pages)
    client = build_client(adapter)
    load_manifest(client)

    assert client.sync_signals
    assert_equal 2, adapter.signal_gets.size
    assert_nil adapter.signal_gets[0][:url].query, "starts from scratch"
    assert_equal "since=c1", adapter.signal_gets[1][:url].query
    assert_equal "Bearer kla_test", adapter.signal_gets[0][:headers]["Authorization"]
    assert_equal "c2", client.signals.cursor
    assert client.signal?("ip.blocked", "203.0.113.1")
    assert client.signal?("ip.blocked", "203.0.113.2")

    assert client.sync_signals
    assert_equal "since=c2", adapter.signal_gets[2][:url].query
  end

  def test_sync_stops_if_the_cursor_does_not_move
    pages = [ { "signals" => [], "cursor" => "0", "more" => true } ]
    adapter = FakeAdapter.new(manifest: SIGNALS_MANIFEST, signal_pages: pages)
    client = build_client(adapter)
    load_manifest(client)
    client.signals.apply_page({ "signals" => [], "cursor" => "0" })
    assert client.sync_signals
    assert_equal 1, adapter.signal_gets.size
  end

  def test_sync_failures_keep_what_is_known
    pages = [ { "signals" => [ signal("ip.blocked", subject: "203.0.113.1") ], "cursor" => "c1", "more" => false },
              403, Errno::ECONNREFUSED.new, 500 ]
    adapter = FakeAdapter.new(manifest: SIGNALS_MANIFEST, signal_pages: pages)
    client = build_client(adapter)
    load_manifest(client)
    assert client.sync_signals
    3.times { refute client.sync_signals }
    assert_equal "c1", client.signals.cursor
    assert client.signal?("ip.blocked", "203.0.113.1")
  end

  def test_worker_polls_signals_after_loading_the_manifest
    pages = [ { "signals" => [ signal("ip.blocked", subject: "203.0.113.9") ], "cursor" => "c1", "more" => false } ]
    adapter = FakeAdapter.new(manifest: SIGNALS_MANIFEST, signal_pages: pages)
    client = build_client(adapter)
    client.start
    wait_until { client.signal?("ip.blocked", "203.0.113.9") }
  end

  def test_signal_query_is_false_when_disabled
    client = build_client(enabled: false)
    client.signals.apply(signal("ip.blocked", subject: "203.0.113.1"))
    refute client.signal?("ip.blocked", "203.0.113.1")
  end

  def test_report_signal_is_queued_and_sent_by_the_worker
    adapter = FakeAdapter.new(manifest: SIGNALS_MANIFEST)
    client = build_client(adapter)
    assert client.report_signal("ip.blocked", " 203.0.113.7 ", reason: "wp-login scan",
                                details: { path: "/wp-login.php", password: "x" })
    wait_until { adapter.reports.size == 1 }

    report = adapter.reports.first
    assert_equal "/api/v1/signals", report[:url].path
    assert_equal "application/json", report[:headers]["Content-Type"]
    assert_equal "Bearer kla_test", report[:headers]["Authorization"]
    assert_equal({ "kind" => "ip.blocked", "subject" => "203.0.113.7", "reason" => "wp-login scan",
                   "details" => { "path" => "/wp-login.php" } }, report[:body])
    assert_empty adapter.posts, "reports don't go through the events endpoint"
  end

  def test_report_signal_rejects_blank_input_and_disabled_clients
    client = build_client
    refute client.report_signal("", "x")
    refute client.report_signal("ip.blocked", "  ")
    refute build_client(enabled: false).report_signal("ip.blocked", "203.0.113.7")
  end

  def test_reports_retry_server_errors_and_drop_client_errors
    adapter = FakeAdapter.new(manifest: SIGNALS_MANIFEST, report_responses: [ 500, 202, 422 ])
    client = build_client(adapter)
    load_manifest(client)
    client.report_signal("ip.blocked", "203.0.113.7")
    client.report_signal("ip.nope", "203.0.113.8")

    client.send_signal_reports
    assert_equal 1, adapter.reports.size
    assert_equal 2, client.pending_reports, "the failed report waits for the next round"

    client.instance_variable_set(:@reports_retry_at, 0.0)
    client.send_signal_reports
    assert_equal 3, adapter.reports.size
    assert_equal 0, client.pending_reports, "the 422 was dropped, not retried"
  end

  def test_reports_give_up_after_three_attempts
    adapter = FakeAdapter.new(manifest: SIGNALS_MANIFEST, report_responses: [ 503, Errno::ECONNREFUSED.new, 500 ])
    client = build_client(adapter)
    load_manifest(client)
    client.report_signal("ip.blocked", "203.0.113.7")
    3.times do
      client.instance_variable_set(:@reports_retry_at, 0.0)
      client.send_signal_reports
    end
    assert_equal 3, adapter.reports.size
    assert_equal 0, client.pending_reports
  end

  def test_reports_dropped_when_the_manifest_lists_no_report_endpoint
    manifest = { "endpoints" => [ { "rel" => "signals", "path" => "/api/v1/signals" } ] }
    adapter = FakeAdapter.new(manifest: manifest)
    client = build_client(adapter)
    load_manifest(client)
    client.report_signal("ip.blocked", "203.0.113.7")
    client.send_signal_reports
    assert_empty adapter.reports
    assert_equal 0, client.pending_reports
  end

  def test_report_queue_is_bounded
    client = build_client
    client.instance_variable_set(:@stopped, true) # no worker, so the queue only grows
    (Kulla::Client::MAX_PENDING_REPORTS + 5).times { |i| client.report_signal("ip.blocked", "10.0.0.#{i % 250}") }
    assert_equal Kulla::Client::MAX_PENDING_REPORTS, client.pending_reports
  end

  def test_module_api_never_raises
    Kulla.stub(:client, -> { raise "boom" }) do
      refute Kulla.signal?("ip.blocked", "203.0.113.1")
      refute Kulla.report_signal("ip.blocked", "203.0.113.1")
    end
  end
end

class MailInterceptorTest < Minitest::Test
  include KullaTestHelpers

  FakeMessage = Struct.new(:to, :cc, :bcc, :perform_deliveries, keyword_init: true)

  def setup
    @client = build_client(suppress_bad_emails: true)
    @client.signals.apply({ "kind" => "email.bounced", "subject_hash" => Digest::SHA256.hexdigest("bounced@example.com"), "state" => "active" })
    @client.signals.apply({ "kind" => "email.complaint", "subject_hash" => Digest::SHA256.hexdigest("angry@example.com"), "state" => "active" })
  end

  def deliver(message)
    Kulla::MailInterceptor.delivering_email(message, client: @client)
    message
  end

  def test_removes_suppressed_recipients_and_keeps_the_rest
    message = deliver(FakeMessage.new(to: [ "ok@example.com", "Bounced@Example.com" ], cc: [ "angry@example.com" ],
                                      bcc: [ "other@example.com" ], perform_deliveries: true))
    assert_equal [ "ok@example.com" ], message.to
    assert_nil message.cc
    assert_equal [ "other@example.com" ], message.bcc
    assert message.perform_deliveries
  end

  def test_cancels_delivery_when_nobody_is_left
    message = deliver(FakeMessage.new(to: [ "Bounced <bounced@example.com>" ], cc: [ "angry@example.com" ], perform_deliveries: true))
    assert_equal false, message.perform_deliveries
  end

  def test_leaves_messages_alone_when_the_toggle_is_off
    @client.config.suppress_bad_emails = false
    message = deliver(FakeMessage.new(to: [ "bounced@example.com" ], perform_deliveries: true))
    assert_equal [ "bounced@example.com" ], message.to
    assert message.perform_deliveries
  end

  def test_never_raises
    broken = Object.new
    def broken.to = raise("broken message")
    def broken.to=(_value)
    end
    assert_nil Kulla::MailInterceptor.delivering_email(broken, client: @client)
  end
end

class SignalBlockerTest < Minitest::Test
  include KullaTestHelpers

  def setup
    @client = build_client(block_signal_ips: true)
    @client.signals.apply(signal("ip.blocked", subject: "203.0.113.66"))
    inner = ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "ok" ] ] }
    @app = Rack::MockRequest.new(Kulla::SignalBlocker.new(inner, client: @client))
  end

  def test_blocks_signalled_ips
    assert_equal 403, @app.get("/", "REMOTE_ADDR" => "203.0.113.66").status
    assert_equal 200, @app.get("/", "REMOTE_ADDR" => "203.0.113.67").status
  end

  def test_prefers_the_remote_ip_rails_resolved
    assert_equal 403, @app.get("/", "REMOTE_ADDR" => "10.0.0.1", "action_dispatch.remote_ip" => "203.0.113.66").status
  end

  def test_passes_everything_when_the_toggle_is_off
    @client.config.block_signal_ips = false
    assert_equal 200, @app.get("/", "REMOTE_ADDR" => "203.0.113.66").status
  end

  def test_toggles_default_off
    config = Kulla::Configuration.new
    refute config.block_signal_ips
    refute config.suppress_bad_emails
  end
end
