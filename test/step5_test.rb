require_relative "test_helper"

class Step5Test < Minitest::Test
  include KullaTestHelpers

  def setup
    @adapter = FakeAdapter.new
    @config = build_config
    @client = Kulla::Client.new(@config, transport: Kulla::Transport.new(@config, adapter: @adapter))
    Kulla::EmailCheck.reset!
  end

  def teardown = @client.stop

  def test_visits_carry_a_truncated_ip_prefix_only
    assert_equal "203.0.113.0", Kulla::VisitEndpoint.ip_prefix("203.0.113.9")
    assert_equal "2001:db8:abcd::", Kulla::VisitEndpoint.ip_prefix("2001:db8:abcd:12::1")
    assert_nil Kulla::VisitEndpoint.ip_prefix("nope")

    endpoint = Kulla::VisitEndpoint.new(->(_) { [ 404, {}, [] ] }, client: @client)
    endpoint.call("PATH_INFO" => Kulla::VisitEndpoint::PATH, "REQUEST_METHOD" => "POST", "REMOTE_ADDR" => "203.0.113.9",
                  "HTTP_USER_AGENT" => "Mozilla/5.0", "rack.input" => StringIO.new(JSON.generate(path: "/")))
    @client.flush
    attrs = @adapter.events.first["attrs"]
    assert_equal "203.0.113.0", attrs["ip_prefix"]
    refute attrs.key?("ip")
  end

  def test_email_check_reports_undeliverable_domains_and_never_raises
    Kulla::EmailCheck.stub(:resolve, ->(domain) { domain == "example.com" }) do
      assert Kulla::EmailCheck.valid?("Jane@Example.com", client: @client)
      refute Kulla::EmailCheck.valid?("x@bogus.invalid", client: @client)
      refute Kulla::EmailCheck.valid?("not-an-email", client: @client)
    end
    assert_equal 1, @client.pending_reports
    @client.send_signal_reports
    report = @adapter.reports.first[:body]
    assert_equal [ "email.invalid", "x@bogus.invalid" ], report.values_at("kind", "subject")
    assert_match "bogus.invalid", report["reason"]
  end

  def test_email_check_refuses_addresses_kulla_already_knows_and_caches_domains
    calls = 0
    Kulla::EmailCheck.stub(:resolve, ->(_) { calls += 1; true }) do
      @client.signals.apply_page("signals" => [ { "kind" => "email.invalid", "subject_hash" => Kulla::SignalStore.hash_email("dead@example.com"), "state" => "active" } ], "cursor" => "1", "more" => false)
      refute Kulla::EmailCheck.valid?("dead@example.com", client: @client)
      assert Kulla::EmailCheck.valid?("live@example.com", client: @client)
      assert Kulla::EmailCheck.valid?("other@example.com", client: @client)
    end
    assert_equal 1, calls, "one DNS lookup per domain per hour"
  end

  def test_webhook_key_derives_from_the_token_and_deliveries_verify
    key = Kulla::Webhook.key_for("kla_test")
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", Digest::SHA256.hexdigest("kla_test"), "kulla-webhook-v1"), key
    assert_nil Kulla::Webhook.key_for(nil)

    body = JSON.generate(event: "signal.updated")
    t = Time.now.to_i
    other = Kulla::Webhook.key_for("kla_other")
    sig = ->(k, at = t, b = body) { OpenSSL::HMAC.hexdigest("SHA256", k, "#{at}.#{b}") }
    synced = 0
    @client.define_singleton_method(:sync_now) { synced += 1 }
    hook = Kulla::Webhook.new(->(_) { [ 404, {}, [] ] }, client: @client) # key from @config.token = "kla_test"
    call = ->(header, b = body) { hook.call("PATH_INFO" => "/kulla/signals", "REQUEST_METHOD" => "POST", "HTTP_X_KULLA_SIGNATURE" => header, "rack.input" => StringIO.new(b)).first }

    assert_equal 204, call.("t=#{t},v1=#{sig.(other)},v1=#{sig.(key)}"), "any of the app's tokens may have signed"
    assert_equal 1, synced
    assert_equal 401, call.("t=#{t},v1=#{sig.(other)}")
    assert_equal 401, call.("t=#{t},v1=#{sig.(key)}", body + " ")
    stale = t - 600
    assert_equal 401, call.("t=#{stale},v1=#{sig.(key, stale)}")
    @config.token = nil
    @config.enroll = false
    assert_equal 404, call.("t=#{t},v1=#{sig.(key)}"), "no token yet, no webhook"
    assert_equal 1, synced
  end
end
