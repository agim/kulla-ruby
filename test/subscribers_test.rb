require "test_helper"

# The subscriber logic without Rails: payloads are built by hand to match what Rails sends.
class SubscribersTest < Minitest::Test
  include KullaTestHelpers

  FakeRequest = Struct.new(:path, :route_uri_pattern, :request_method, :remote_ip, :request_id, :headers, keyword_init: true) do
    def get_header(name) = headers[name]
  end
  FakeJob = Struct.new(:queue_name, :executions, :job_id)
  class ReportJob < FakeJob; end
  FakeAttackRequest = Struct.new(:env, :ip, :path)

  def request_payload(path: "/users/42", pattern: "/users/:id(.:format)", **extra)
    headers = { "HTTP_USER_AGENT" => "Mozilla/5.0", "HTTP_CF_IPCOUNTRY" => "XK" }
    request = FakeRequest.new(path: path, route_uri_pattern: pattern, request_method: "GET", remote_ip: "198.51.100.7",
                              request_id: "req-1", headers: headers)
    { request: request, headers: headers, controller: "UsersController", action: "show", method: "GET",
      path: "#{path}?page=2", status: 200, db_runtime: 3.14159, view_runtime: 10.05 }.merge(extra)
  end

  def test_request_attrs
    attrs, trace = Kulla::Subscribers::Requests.attrs_for(request_payload, 25.678)

    assert_equal "req-1", trace
    assert_equal({ "method" => "GET", "path" => "/users/:id", "status" => 200, "duration_ms" => 25.7, "db_ms" => 3.1,
                   "view_ms" => 10.1, "controller" => "UsersController", "action" => "show", "ip" => "198.51.100.7",
                   "ua" => "Mozilla/5.0", "country" => "XK", "bot" => false }, attrs)
  end

  def test_request_falls_back_to_raw_path_and_500_on_exception
    payload = request_payload(pattern: nil).merge(status: nil, exception: [ "RuntimeError", "boom" ])
    attrs, = Kulla::Subscribers::Requests.attrs_for(payload, 1.0)
    assert_equal "/users/42", attrs["path"]
    assert_equal 500, attrs["status"]
  end

  def test_request_skips_noise_paths
    %w[/up /assets/app.css /rails/active_storage/blobs/x /cable].each do |path|
      assert_nil Kulla::Subscribers::Requests.attrs_for(request_payload(path: path), 1.0), path
    end
    refute_nil Kulla::Subscribers::Requests.attrs_for(request_payload(path: "/uploads"), 1.0)
  end

  def test_job_attrs
    ok = Kulla::Subscribers::Jobs.attrs_for({ job: ReportJob.new("default", 2, "j-1") }, 1234.56)
    assert_equal({ "class" => "SubscribersTest::ReportJob", "queue" => "default", "duration_ms" => 1234.6,
                   "result" => "ok", "attempts" => 2, "job_id" => "j-1" }, ok)

    failed = Kulla::Subscribers::Jobs.attrs_for({ job: ReportJob.new("default", 1, "j-2"), exception_object: RuntimeError.new }, 1)
    assert_equal "failed", failed["result"]
  end

  def test_mail_attrs
    attrs = Kulla::Subscribers::Mail.attrs_for({ mailer: "UserMailer", message_id: "m@x", to: [ "a@b.c", "d@e.f" ] })
    assert_equal({ "status" => "sent", "mailer" => "UserMailer", "message_id" => "m@x", "email" => "a@b.c" }, attrs)
    assert_nil Kulla::Subscribers::Mail.attrs_for({ perform_deliveries: false })
  end

  def test_mail_email_survives_filter_parameters
    adapter = FakeAdapter.new
    client = build_client(adapter, filter_parameters: [ :email ])
    event = Struct.new(:payload).new({ mailer: "UserMailer", to: "a@b.c" })
    Kulla::Subscribers::Mail.track(client, event)
    client.flush
    assert_equal "a@b.c", adapter.events.first["attrs"]["email"]
  end

  def test_security_attrs_for_both_payload_shapes
    env = { "rack.attack.match_type" => :throttle, "rack.attack.matched" => "req/ip" }
    request = FakeAttackRequest.new(env, "192.0.2.1", "/login")
    expected = { "rule" => "req/ip", "match_type" => "throttle", "ip" => "192.0.2.1", "path" => "/login" }

    assert_equal expected, Kulla::Subscribers::Security.attrs_for({ request: request })
    assert_equal expected, Kulla::Subscribers::Security.attrs_for(request)
    safelisted = FakeAttackRequest.new({ "rack.attack.match_type" => :safelist }, "1.1.1.1", "/")
    assert_nil Kulla::Subscribers::Security.attrs_for({ request: safelisted })
  end

  def test_structured_events
    adapter = FakeAdapter.new
    client = build_client(adapter, filter_parameters: [ :card ])
    subscriber = Kulla::Subscribers::Events.new(client)
    ts = 1_738_964_843_208_679_035

    subscriber.emit({ name: "User.Signup", payload: { plan: "pro", card: "4242" }, tags: { graphql: true },
                      context: { request_id: "req-9" }, timestamp: ts })
    subscriber.emit({ name: "kulla.internal", payload: {}, tags: {}, context: {}, timestamp: ts })
    subscriber.emit({ name: "action_controller.request_completed", payload: {}, tags: {}, context: {}, timestamp: ts })
    client.flush

    assert_equal 1, adapter.events.size
    event = adapter.events.first
    assert_equal "user.signup", event["stream"]
    assert_equal "req-9", event["trace"]
    assert_equal "2025-02-07T21:47:23.208Z", event["ts"]
    assert_equal({ "plan" => "pro", "card" => "[FILTERED]", "tags" => { "graphql" => true },
                   "context" => { "request_id" => "req-9" } }, event["attrs"])
    refute subscriber.wanted?({ name: "active_job.completed" })
  end

  def test_errors_subscriber_extracts_controller_and_job_context
    controller = Struct.new(:action_name, :request).new("show", FakeRequest.new(path: "/x", request_method: "GET", request_id: "req-3"))
    attrs, trace = Kulla::Subscribers::Errors.attrs_for(RuntimeError.new("x"), context: { controller: controller, job: ReportJob.new("q", 1, "j") },
                                                       handled: true, severity: :warning, source: "s", config: build_config)
    assert_equal "req-3", trace
    assert_equal "show", attrs["context"]["action"]
    assert_equal "SubscribersTest::ReportJob", attrs["context"]["job_class"]
    assert_equal [], attrs["backtrace"]
    assert_equal "warning", attrs["severity"]
  end

  def test_backtrace_format_and_app_frames
    error = RuntimeError.new("x")
    error.set_backtrace([
      "/srv/app/app/models/user.rb:12:in 'User#save'",
      "/srv/app/vendor/bundle/gems/x/lib/x.rb:1:in `call'",
      "/usr/lib/ruby/3.4.0/foo.rb:3:in 'Foo.bar'",
      "/srv/app/app/controllers/users_controller.rb:5:in 'UsersController#create'"
    ])
    frames = Kulla::Subscribers::Errors.backtrace(error, "/srv/app")

    assert_equal "app/models/user.rb:12 in 'User#save'", frames[0]
    assert_equal "vendor/bundle/gems/x/lib/x.rb:1 in 'call'", frames[1]
    assert_equal "/usr/lib/ruby/3.4.0/foo.rb:3 in 'Foo.bar'", frames[2]
    assert_equal 2, frames.count { |f| Kulla::Subscribers::Errors.app_frame?(f) }
  end

  def test_heartbeat_collects_process_stats
    attrs = Kulla::Subscribers::Heartbeat.collect(build_config)
    assert_kind_of Integer, attrs["threads"]
    if File.exist?("/proc/self/status")
      assert_operator attrs["rss_mb"], :>, 0
      assert_kind_of Float, attrs["load"]
    end
    JSON.generate(attrs)
  end

  def test_deploy_attrs_send_env_names_only
    ENV["KULLA_TEST_SECRET"] = "hunter2"
    attrs = Kulla::Subscribers::Deploy.attrs(build_config)

    assert_equal "abc1234", attrs["revision"]
    assert_equal RUBY_VERSION, attrs["ruby"]
    assert_includes attrs["env_names"], "KULLA_TEST_SECRET"
    refute_includes JSON.generate(attrs), "hunter2"
    assert_kind_of Hash, attrs["gems"]
    assert_operator attrs["gems"].size, :<=, 400
  ensure
    ENV.delete("KULLA_TEST_SECRET")
  end
end
