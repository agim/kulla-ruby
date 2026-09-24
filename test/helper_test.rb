require "test_helper"

class HelperTest < Minitest::Test
  include KullaTestHelpers

  class View
    include Kulla::Helper
  end

  class NonceView < View
    def content_security_policy_nonce = "abc\"123"
  end

  def setup
    Kulla.configure do |c|
      c.token = "kla_test"
      c.endpoint = "https://kulla.example"
      c.env = "production"
      c.logger = nil
    end
  end

  def test_renders_inline_beacon_posting_to_the_app
    html = View.new.kulla_beacon_tag
    assert html.start_with?("<script>")
    assert_includes html, '"/kulla/visit"'
    assert_includes html, "sendBeacon"
    assert_includes html, "PerformanceObserver"
    refute_includes html, "kla_test"
  end

  def test_uses_the_csp_nonce
    assert NonceView.new.kulla_beacon_tag.start_with?('<script nonce="abc&quot;123">')
  end

  def test_renders_nothing_when_disabled
    Kulla.config.enabled = false
    assert_nil View.new.kulla_beacon_tag
  end

  def test_escapes_the_path
    refute_includes Kulla::Helper.beacon_js("/x</script>"), "</script>"
  end
end
