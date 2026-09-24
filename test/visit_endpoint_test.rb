require "test_helper"

begin
  require "rack/mock"
rescue LoadError
  nil
end

class VisitEndpointTest < Minitest::Test
  include KullaTestHelpers

  CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36".freeze

  def setup
    skip "rack is not available" unless defined?(Rack::MockRequest)
    @adapter = FakeAdapter.new
    @client = build_client(@adapter)
    app = ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "app" ] ] }
    @request = Rack::MockRequest.new(Kulla::VisitEndpoint.new(app, client: @client, secret: "s3cret"))
  end

  def beacon(body, **env)
    @request.post("/kulla/visit", { input: body.is_a?(String) ? body : JSON.generate(body), "HTTP_USER_AGENT" => CHROME,
                                    "REMOTE_ADDR" => "203.0.113.9" }.merge(env))
  end

  def visits
    @client.flush
    @adapter.events.select { |e| e["stream"] == "visit" }
  end

  def test_records_a_visit_and_answers_204
    response = beacon({ path: "/pricing?coupon=abc", referrer: "https://google.com/search?q=secret", viewport: "1440x900",
                        device: "desktop", lcp_ms: 812.4, inp_ms: 96, cls: 0.01234 })

    assert_equal 204, response.status
    attrs = visits.first["attrs"]
    assert_equal "/pricing", attrs["path"]
    assert_equal "https://google.com/search", attrs["referrer"]
    assert_equal "1440x900", attrs["viewport"]
    assert_equal "desktop", attrs["device"]
    assert_equal 812, attrs["lcp_ms"]
    assert_equal 96, attrs["inp_ms"]
    assert_equal 0.0123, attrs["cls"]
    assert_equal false, attrs["bot"]
    refute attrs.key?("ip")

    salt = "#{Time.now.utc.strftime("%Y-%m-%d")}s3cret"
    assert_equal Digest::SHA256.hexdigest("#{salt}203.0.113.9#{CHROME}")[0, 16], attrs["visitor"]
    assert_match(/\A[0-9a-f]{16}\z/, attrs["visitor"])
  end

  def test_flags_bots_and_guesses_device
    beacon({ path: "/" }, "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)")
    beacon({ path: "/", device: "fridge", viewport: "big" }, "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Mobile")

    bot, phone = visits.map { |v| v["attrs"] }
    assert_equal true, bot["bot"]
    assert_equal "phone", phone["device"]
    refute phone.key?("viewport")
  end

  def test_ignores_garbage_cross_site_and_oversized_bodies
    assert_equal 204, beacon("not json").status
    assert_equal 204, beacon({ path: "https://evil.example/" }).status
    assert_equal 204, beacon({ path: "/" }, "HTTP_SEC_FETCH_SITE" => "cross-site").status
    assert_equal 204, beacon({ path: "/", pad: "x" * 5_000 }).status
    assert_empty visits
  end

  def test_frames_keep_no_tokens_queries_or_origins
    clean = ->(line) { Kulla::VisitEndpoint.clean_frame(line) }
    assert_equal "handleClick@/q/:token:412:17", clean.call("handleClick@https://portal.example/q/op4xfzpUjX9ab2cdEFqU-8a:412:17")
    assert_equal "HTMLButtonElement.<anonymous> (/q/:token:88:3)", clean.call("HTMLButtonElement.<anonymous> (https://shop.example/q/op4xfzpUjX9ab2cdEFqU-8a?x=1:88:3)")
    assert_equal "/passwords/:token/edit:12:5", clean.call("https://shop.example/passwords/abcDEF1234567890abcdef/edit:12:5")
    assert_equal "/assets/app.js:1:2", clean.call("https://shop.example/assets/app-0123456789abcdef.js?v=3#x:1:2")
    assert_equal "onload@/orders/42:7:1", clean.call("onload@https://shop.example/orders/42:7:1")
  end

  def test_other_paths_and_methods
    assert_equal "app", @request.get("/kulla/visits").body
    assert_equal "app", @request.post("/other").body
    assert_equal 405, @request.get("/kulla/visit").status
  end

  def test_disabled_answers_204_without_recording
    @client.config.enabled = false
    assert_equal 204, beacon({ path: "/" }).status
    @client.config.enabled = true
    assert_empty visits
  end
end
