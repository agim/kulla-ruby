# Boots a tiny Rails app with the Railtie. Runs in its own process (rake test:rails).
begin
  require "rails"
  require "action_controller/railtie"
  require "action_mailer/railtie"
rescue LoadError
  RAILS_UNAVAILABLE = true
end

require "test_helper"
require "rack/mock"

unless defined?(RAILS_UNAVAILABLE)
  ADAPTER = FakeAdapter.new

  class KullaTestApp < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "k" * 64
    config.hosts.clear
    config.filter_parameters += [ :passw ]
    config.action_dispatch.show_exceptions = :all
    config.action_mailer.delivery_method = :test

    routes.append do
      get "/things/:id" => "things#show"
      get "/up" => "things#up"
      get "/boom" => "things#boom"
    end
  end

  class ThingsController < ActionController::Base
    def show
      Rails.event.notify("Thing.Viewed", id: params[:id], password: "hunter2")
      render plain: "thing"
    end

    def up = head(:ok)
    def boom = raise("kaboom")
  end

  class NoticeMailer < ActionMailer::Base
    default from: "app@example.com"

    def notice(to, cc = nil)
      mail(to: to, cc: cc, subject: "Notice") { |format| format.text { render plain: "hi" } }
    end
  end

  Kulla.configure do |c|
    c.token = "kla_test"
    c.endpoint = "https://kulla.example"
    c.env = "production"
    c.logger = nil
    c.flush_interval = 3600
    c.transport = Kulla::Transport.new(c, adapter: ADAPTER, sleeper: ->(_) { })
    c.block_signal_ips = true
    c.suppress_bad_emails = true
  end
  KullaTestApp.initialize!
end

class RailtieTest < Minitest::Test
  def setup
    skip "Rails is not available" if defined?(RAILS_UNAVAILABLE)
    Kulla.client.flush
    ADAPTER.posts.clear
    @app = Rack::MockRequest.new(Rails.application)
  end

  def events(stream = nil)
    Kulla.client.flush
    all = ADAPTER.events
    stream ? all.select { |e| e["stream"] == stream } : all
  end

  def test_middleware_and_helper_are_installed
    stack = Rails.application.middleware.map(&:klass)
    assert_includes stack, Kulla::VisitEndpoint
    assert_operator stack.index(Kulla::VisitEndpoint), :>, stack.index(ActionDispatch::RemoteIp)
    assert ActionView::Base.method_defined?(:kulla_beacon_tag)
  end

  def test_filter_parameters_come_from_rails
    assert_includes Kulla.config.filter_parameters, :passw
  end

  def test_requests_use_the_route_template_and_skip_up
    @app.get("/things/42", "HTTP_USER_AGENT" => "Mozilla/5.0", "REMOTE_ADDR" => "198.51.100.7")
    @app.get("/up")

    requests = events("request")
    assert_equal 1, requests.size
    attrs = requests.first["attrs"]
    assert_equal "/things/:id", attrs["path"]
    assert_equal 200, attrs["status"]
    assert_equal "ThingsController", attrs["controller"]
    assert_equal "show", attrs["action"]
    assert_equal "198.51.100.7", attrs["ip"]
    refute_nil requests.first["trace"]
  end

  def test_structured_events_are_forwarded_and_framework_events_ignored
    @app.get("/things/7")

    streams = events.map { |e| e["stream"] }
    assert_includes streams, "thing.viewed"
    assert streams.none? { |s| s.start_with?("action_controller.", "action_dispatch.", "action_view.") }, streams.inspect
    viewed = events("thing.viewed")
    assert_equal "7", viewed.first["attrs"]["id"]
    refute_includes JSON.generate(viewed), "hunter2"
  end

  def test_errors_reported_to_rails_error
    Rails.error.report(ArgumentError.new("nope"), handled: true, severity: :warning, context: { order_id: 1, passwd: "x" })

    error = events("error").first
    assert_equal "warn", error["level"]
    assert_equal "ArgumentError", error["attrs"]["class"]
    assert_equal({ "order_id" => 1 }, error["attrs"]["context"])
  end

  def test_unhandled_controller_errors
    response = @app.get("/boom")
    assert_equal 500, response.status

    request = events("request").first
    assert_equal 500, request["attrs"]["status"]
    assert_equal "error", request["level"]

    error = events("error").first
    assert_equal "RuntimeError", error["attrs"]["class"]
    assert_equal false, error["attrs"]["handled"]
    assert_equal "ThingsController", error["attrs"]["context"]["controller"]
    assert_equal request["trace"], error["trace"]
  end

  def test_signal_blocker_sits_right_after_remote_ip
    stack = Rails.application.middleware.map(&:klass)
    assert_equal stack.index(ActionDispatch::RemoteIp) + 1, stack.index(Kulla::SignalBlocker)
  end

  def test_signalled_ips_get_403
    Kulla.client.signals.apply({ "kind" => "ip.blocked", "subject" => "203.0.113.66", "state" => "active" })
    assert_equal 403, @app.get("/things/1", "REMOTE_ADDR" => "203.0.113.66").status
    assert_equal 200, @app.get("/things/1", "REMOTE_ADDR" => "203.0.113.67").status
  ensure
    Kulla.client.signals.clear
  end

  def test_mail_to_bounced_addresses_is_suppressed
    hash = Digest::SHA256.hexdigest("bounced@example.com")
    Kulla.client.signals.apply({ "kind" => "email.bounced", "subject_hash" => hash, "state" => "active" })
    ActionMailer::Base.deliveries.clear

    NoticeMailer.notice("Bounced@example.com").deliver_now
    assert_empty ActionMailer::Base.deliveries, "nobody left: delivery cancelled"

    NoticeMailer.notice([ "ok@example.com", "bounced@example.com" ], "bounced@example.com").deliver_now
    assert_equal 1, ActionMailer::Base.deliveries.size
    delivered = ActionMailer::Base.deliveries.first
    assert_equal [ "ok@example.com" ], delivered.to
    assert_empty Array(delivered.cc)
  ensure
    Kulla.client.signals.clear
  end

  def test_visit_endpoint_in_the_stack
    # sendBeacon posts text/plain; MockRequest defaults to a form content type, which
    # Rack::MethodOverride reads first. Both must work.
    [ "text/plain;charset=UTF-8", nil ].each do |type|
      env = { input: JSON.generate(path: "/things/1"), "HTTP_USER_AGENT" => "Mozilla/5.0" }
      env["CONTENT_TYPE"] = type if type
      assert_equal 204, @app.post("/kulla/visit", env).status
    end
    assert_equal [ "/things/1" ] * 2, events("visit").map { |e| e["attrs"]["path"] }
  end
end
