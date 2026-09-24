require_relative "test_helper"

class BeaconInjectorTest < Minitest::Test
  include KullaTestHelpers

  def setup
    @config = build_config
  end

  def app_returning(status, type, body, extra = {})
    ->(_env) { [ status, { "content-type" => type, "content-length" => body.bytesize.to_s }.merge(extra), [ body ] ] }
  end

  def call(app, env = {})
    Kulla::BeaconInjector.new(app, config: @config).call({ "REQUEST_METHOD" => "GET", "PATH_INFO" => "/" }.merge(env))
  end

  PAGE = "<!doctype html><html><head><title>x</title></head><body>hi</body></html>".freeze

  def test_injects_the_beacon_before_head_ends_and_fixes_content_length
    status, headers, body = call(app_returning(200, "text/html; charset=utf-8", PAGE))
    html = body.join
    assert_equal 200, status
    assert_match %r{<script>\(function\(\)\{.*window\.__kulla.*\}\)\(\);</script></head>}, html
    assert_includes html, '"/kulla/visit"'
    assert_equal html.bytesize.to_s, headers["content-length"]
  end

  def test_uses_the_csp_nonce_and_never_doubles_up
    _, _, body = call(app_returning(200, "text/html", PAGE), "action_dispatch.content_security_policy_nonce" => "n0nce")
    assert_includes body.join, '<script nonce="n0nce">'

    tagged = PAGE.sub("</head>", "<script>window.__kulla=1</script></head>")
    _, _, body = call(app_returning(200, "text/html", tagged))
    assert_equal 1, body.join.scan("window.__kulla").size
  end

  def test_leaves_everything_else_alone
    skip_cases = {
      "json" => [ app_returning(200, "application/json", "{}"), {} ],
      "not found" => [ app_returning(404, "text/html", PAGE), {} ],
      "turbo frame" => [ app_returning(200, "text/html", PAGE), { "HTTP_TURBO_FRAME" => "modal" } ],
      "turbo stream" => [ app_returning(200, "text/html", PAGE), { "HTTP_ACCEPT" => "text/vnd.turbo-stream.html, text/html" } ],
      "xhr" => [ app_returning(200, "text/html", PAGE), { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" } ],
      "post" => [ app_returning(200, "text/html", PAGE), { "REQUEST_METHOD" => "POST" } ],
      "fragment" => [ app_returning(200, "text/html", "<div>partial</div>"), {} ]
    }
    skip_cases.each do |name, (app, env)|
      _, _, body = call(app, env)
      refute_includes body.join, "__kulla", name
    end

    streamed = ->(_env) { [ 200, { "content-type" => "text/html" }, Enumerator.new { |y| y << PAGE } ] }
    _, _, body = call(streamed)
    refute body.respond_to?(:to_ary), "a streamed body is passed through"

    @config.capture = { beacon: false }
    _, _, body = call(app_returning(200, "text/html", PAGE))
    refute_includes body.join, "__kulla"
  end
end
