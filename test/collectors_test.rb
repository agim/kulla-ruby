require_relative "test_helper"

class CollectorsTest < Minitest::Test
  include KullaTestHelpers

  FakeEvent = Struct.new(:payload, :duration)

  def setup
    @adapter = FakeAdapter.new
    @config = build_config
    @client = Kulla::Client.new(@config, transport: Kulla::Transport.new(@config, adapter: @adapter))
  end

  def teardown
    Kulla::Context.store[Kulla::Context::KEY] = nil
    @client.stop
  end

  def events(stream = nil)
    @client.flush
    all = @adapter.events
    stream ? all.select { |e| e["stream"] == stream } : all
  end

  def test_sql_is_normalized_so_no_values_leave_the_app
    sql = %(SELECT "users".* FROM "users" WHERE "users"."email" = 'a@b.co' AND "id" IN (1, 2, 3) LIMIT $1)
    assert_equal %(SELECT "users".* FROM "users" WHERE "users"."email" = ? AND "id" IN (?) LIMIT ?), Kulla::Subscribers::Sql.normalize(sql)
  end

  def test_repeated_selects_in_one_request_are_reported_as_n_plus_one
    ctx = Kulla::Context.start(trace: "req-1", label: "PostsController#index")
    12.times { |i| Kulla::Subscribers::Sql.track(@client, FakeEvent.new({ sql: %(SELECT * FROM "comments" WHERE "post_id" = #{i}), name: "Comment Load" }, 0.4)) }
    Kulla::Context.finish
    Kulla::Subscribers::Sql.report_n_plus_one(@client, ctx)

    n1 = events("query").find { |e| e["attrs"]["kind"] == "n_plus_one" }
    assert_equal 12, n1["attrs"]["count"]
    assert_equal "PostsController#index", n1["attrs"]["where"]
    assert_equal "req-1", n1["trace"]
    assert_equal({ "queries" => 12 }, ctx.counters)
  end

  def test_slow_queries_and_inserts
    @config.slow_query_ms = 100
    Kulla::Subscribers::Sql.track(@client, FakeEvent.new({ sql: %(SELECT pg_sleep(1)), name: "SQL" }, 250.0))
    2.times { Kulla::Subscribers::Sql.track(@client, FakeEvent.new({ sql: %(INSERT INTO "users" ("email") VALUES ('x')), name: "User Create" }, 1.0)) }
    Kulla::Subscribers::Sql.track(@client, FakeEvent.new({ sql: %(INSERT INTO "solid_queue_jobs" ("x") VALUES (1)), name: "SolidQueue::Job Create" }, 1.0))
    Kulla::Subscribers::Sql.track(@client, FakeEvent.new({ sql: %(SELECT 1), name: "SCHEMA" }, 900.0))
    @client.send(:flush_activity)

    slow = events("query")
    assert_equal [ "slow" ], slow.map { |e| e["attrs"]["kind"] }
    assert_equal 250.0, slow.first["attrs"]["duration_ms"]
    assert_equal [ { "table" => "users", "inserts" => 2 } ], events("activity").map { |e| e["attrs"] }
  end

  def test_remote_config_applies_unless_the_app_set_it
    @config.capture = { http: true }
    @config.slow_query_ms = 50
    @config.apply_remote("capture" => { "http" => false, "logs" => false }, "slow_query_ms" => 900, "n_plus_one" => 4, "notifications" => [ "cache_write.active_support" ])
    assert @config.capture?(:http), "the app's own toggle wins"
    refute @config.capture?(:logs)
    assert_equal 50, @config.slow_query_ms
    assert_equal 4, @config.n_plus_one
    assert_equal [ "cache_write.active_support" ], @config.notifications
  end

  def test_breadcrumbs_keep_the_last_twenty
    ctx = Kulla::Context.start
    25.times { |i| ctx.breadcrumb("log", "line #{i}") }
    assert_equal 20, ctx.breadcrumbs.size
    assert_equal "line 24", ctx.breadcrumbs.last["message"]
    Kulla::Context.finish
    assert_same ctx, Kulla::Context.last
  end

  def test_heartbeat_names_the_process
    @config.process_role = "task"
    hb = Kulla::Subscribers::Heartbeat.collect(@config)
    assert_equal Process.pid, hb["pid"]
    assert_equal "task", hb["role"]
    assert_equal Kulla::VERSION, hb["sdk"]
  end

  def test_llm_calls_report_tokens_and_cost_never_text
    model = Struct.new(:id, :provider, :input_price_per_million, :output_price_per_million).new("claude-haiku-4-5", "anthropic", 1.0, 5.0)
    chat = Struct.new(:model).new(model)
    message = Struct.new(:input_tokens, :output_tokens, :model_id, :content).new(1000, 200, "claude-haiku-4-5", "secret reply")
    Kulla.stub(:client, @client) { Kulla::Subscribers::Llm.record(chat, message, Process.clock_gettime(Process::CLOCK_MONOTONIC), nil) }
    llm = events("llm").first["attrs"]
    assert_equal({ "provider" => "anthropic", "model" => "claude-haiku-4-5", "input_tokens" => 1000, "output_tokens" => 200, "cost_usd" => 0.002 }, llm.except("duration_ms"))
  end

  def test_outgoing_http_is_recorded_without_query_strings
    req = Net::HTTP::Get.new("/v3/charges?api_key=sekret")
    http = Net::HTTP.new("api.stripe.com", 443)
    response = Struct.new(:code).new("200")
    Kulla.stub(:client, @client) { Kulla::Subscribers::Http.record(http, req, response, Process.clock_gettime(Process::CLOCK_MONOTONIC), nil) }
    attrs = events("http").first["attrs"]
    assert_equal({ "host" => "api.stripe.com", "method" => "GET", "path" => "/v3/charges", "status" => 200 }, attrs.except("duration_ms"))
  end

  def test_browser_errors_and_csp_reports_come_through_the_app
    endpoint = Kulla::VisitEndpoint.new(->(_) { [ 404, {}, [] ] }, client: @client)
    post = ->(path, body) { endpoint.call("PATH_INFO" => path, "REQUEST_METHOD" => "POST", "rack.input" => StringIO.new(JSON.generate(body))) }

    post.(Kulla::VisitEndpoint::PATH, { type: "error", name: "TypeError", message: "x is undefined", path: "/cart?coupon=1",
          stack: "TypeError: x is undefined\n    at checkout (https://shop.example/assets/application-3f9a1c2b.js:1:2345)" })
    error = events("error").first
    assert_equal "browser", error["attrs"]["source"]
    assert_equal [ "checkout (/assets/application.js:1:2345)" ], error["attrs"]["backtrace"]
    assert_equal "/cart", error["attrs"]["context"]["path"]

    post.(Kulla::VisitEndpoint::CSP_PATH, { "csp-report" => { "effective-directive" => "script-src", "blocked-uri" => "https://evil.example/x.js?t=1", "document-uri" => "https://shop.example/pay?x=1" } })
    csp = events("csp").first["attrs"]
    assert_equal({ "directive" => "script-src", "blocked" => "https://evil.example", "path" => "/pay", "disposition" => "enforce" }, csp)
  end

  def test_warn_and_error_logs_are_sent_at_most_n_per_minute
    @config.logs_per_minute = 2
    logger = Kulla::Subscribers::Logs.new(@client)
    logger.info("fine")
    3.times { |i| logger.warn("disk low #{i}") }
    logger.error("[kulla] never about itself")
    assert_equal [ "disk low 0", "disk low 1" ], events("log").map { |e| e["message"] }
  end

  def test_security_events_from_the_app
    Kulla.stub(:client, @client) do
      Kulla.stub(:config, @config) { Kulla.security("login_failed", ip: "203.0.113.9", path: "/session") }
    end
    assert_equal({ "rule" => "login_failed", "match_type" => "app", "ip" => "203.0.113.9", "path" => "/session" }, events("security").first["attrs"])
  end

  def test_free_text_loses_emails_tokens_numbers_and_query_strings
    text = "Throttled /portal/q?t=8f2Kx9LmQ2pZ7wT4vB1nR6yU for jane@example.com, call +355 69 123 4567, sig data:image/png;base64,iVBORw0KGgo="
    assert_equal "Throttled /portal/q?[query] for [email], call [number], sig [data]", Kulla::Scrubber.clean_content(text)
    assert_equal "/portal/:token/sign", Kulla::Scrubber.clean_path("/portal/8f2Kx9LmQ2pZ7wT4vB1n/sign")
    assert_equal "/users/42/edit", Kulla::Scrubber.clean_path("/users/42/edit")
  end

  def test_personal_fields_are_filtered_whatever_the_app_configured
    scrubbed = Kulla::Scrubber.new([]).call({ "phone" => "+1 555 0100", "billing_address" => "1 Main St", "signature" => "iVBOR…", "plan" => "pro" })
    assert_equal({ "phone" => "[FILTERED]", "billing_address" => "[FILTERED]", "signature" => "[FILTERED]", "plan" => "pro" }, scrubbed)
    assert_equal({ "signer_name" => "[FILTERED]", "id" => "7" }, Kulla::Scrubber.filter_names({ "signer_name" => "Jane", "id" => "7" }))
  end

  def test_log_lines_are_scrubbed
    Kulla::Subscribers::Logs.new(@client).warn("Rack::Attack throttled GET /portal/abc?token=8f2Kx9LmQ2pZ7wT4vB1nR6yU from jane@example.com")
    assert_equal "Rack::Attack throttled GET /portal/abc?[query] from [email]", events("log").first["message"]
  end

  def test_remote_notifications_cannot_reach_sensitive_events_or_fields
    denied = Kulla::Subscribers::Generic::DENIED
    %w[process_action.action_controller sql.active_record deliver.action_mailer perform.active_job].each { |name| assert_match denied, name }
    refute_match denied, "cache_write.active_support"

    event = Struct.new(:payload, :duration).new({ key: "views/users/jane@example.com", path: "/reset/abc", store: "SolidCache", hit: true, note: "for jane@example.com" }, 1.25)
    Kulla::Subscribers::Generic.track(@client, "cache_write.active_support", event)
    assert_equal({ "store" => "SolidCache", "hit" => true, "note" => "for [email]", "duration_ms" => 1.3 }, events("cache_write.active_support").first["attrs"])
  end
end
