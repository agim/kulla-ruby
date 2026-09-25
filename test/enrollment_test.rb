require_relative "test_helper"

class EnrollmentTest < Minitest::Test
  include KullaTestHelpers

  # Answers /api/v1/enroll from a queue of states; everything else goes to FakeAdapter.
  ISSUED = "kla_issued_by_kulla".freeze

  class EnrollAdapter < FakeAdapter
    attr_reader :enrolls

    def initialize(states, **options)
      super(**options)
      @states = states
      @enrolls = []
    end

    def post(url, body, headers)
      return super unless url.path == Kulla::Transport::ENROLL_PATH

      @enrolls << { body: JSON.parse(body), headers: headers }
      state = @states.shift || "pending"
      body = state == "approved" ? { state: state, token: ISSUED } : { state: state }
      Kulla::Transport::Response.new({ "approved" => 200, "rejected" => 403 }.fetch(state, 202), {}, JSON.generate(body))
    end
  end

  def enrolling_config(key: "kli_#{"k" * 43}")
    build_config(token: nil, enroll: true, app_name: "Shop").tap do |c|
      c.instance_variable_set(:@enrollment_key, key)
    end
  end

  def test_enrollment_key_is_stable_and_shaped_like_a_token
    config = Kulla::Configuration.new
    secret = "s" * 64
    key = config.send(:base58, OpenSSL::HMAC.digest("SHA256", secret, Kulla::Configuration::ENROLL_CONTEXT))
    assert_equal key, config.send(:base58, OpenSSL::HMAC.digest("SHA256", secret, Kulla::Configuration::ENROLL_CONTEXT))
    assert_match(/\A[1-9A-HJ-NP-Za-km-z]{40,64}\z/, key)
    refute_equal key, config.send(:base58, OpenSSL::HMAC.digest("SHA256", "t" * 64, Kulla::Configuration::ENROLL_CONTEXT))
  end

  def test_a_configured_token_skips_enrollment
    config = build_config
    refute config.enrolling?
    assert Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: FakeAdapter.new)).approved?
  end

  def test_enroll_sends_the_key_and_app_details_without_a_bearer_token
    config = enrolling_config
    adapter = EnrollAdapter.new([ "pending" ])
    assert_equal [ "pending", nil ], Kulla::Transport.new(config, adapter: adapter).enroll

    sent = adapter.enrolls.first
    assert_equal({ "key" => config.enrollment_key, "name" => "Shop", "host" => "test-host", "env" => "production", "sdk" => Kulla::VERSION },
                 sent[:body])
    assert_nil sent[:headers]["Authorization"]
    assert_nil sent[:headers]["X-Kulla-Site"]
  end

  def test_the_site_names_the_app_and_rides_on_every_request
    config = enrolling_config
    config.site = "Shop.Example-Store.com"
    config.app_name = nil
    assert_equal "shop.example-store.com", config.site
    assert_equal "shop.example-store.com", config.app_name

    adapter = EnrollAdapter.new([ "pending" ])
    Kulla::Transport.new(config, adapter: adapter).enroll
    sent = adapter.enrolls.first
    assert_equal "shop.example-store.com", sent[:body]["site"]
    assert_equal "shop.example-store.com", sent[:body]["name"]
    assert_equal "shop.example-store.com", sent[:headers]["X-Kulla-Site"]
  end

  def test_joining_without_a_site_says_so_once
    config = enrolling_config
    lines = []
    previous = Kulla.config.logger
    Kulla.config.logger = Struct.new(:lines) { def warn(m) = lines << m; def info(_m) = nil; def debug(_m) = nil }.new(lines)
    adapter = EnrollAdapter.new([ "pending", "pending" ])
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: adapter))
    2.times { client.send(:check_approval) }
    assert_equal 1, lines.count { |l| l.include?("no site detected") }, lines.inspect
    assert_includes lines.first, '"Shop"'
  ensure
    Kulla.config.logger = previous
  end

  def test_placeholder_hosts_never_become_the_site
    assert_nil Kulla::Configuration.hostname("example.com")
    assert_nil Kulla::Configuration.hostname("www.example.org")
    assert_nil Kulla::Configuration.hostname("localhost")
    assert_nil Kulla::Configuration.hostname("shop.test")
    assert_nil Kulla::Configuration.hostname("10.0.0.1")
    assert_nil Kulla::Configuration.hostname("")
    assert_equal "shop.example-store.com", Kulla::Configuration.hostname("https://Shop.example-store.com:3000/path")
    assert_equal "shop-store.com", Kulla::Configuration.hostname("shop-store.com")
  end

  def test_events_wait_in_the_buffer_until_approved_then_go_out_with_the_issued_token
    config = enrolling_config
    adapter = EnrollAdapter.new([ "pending", "approved" ])
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: adapter))
    refute client.approved?

    client.track("log", { "n" => 1 })
    client.send(:check_approval)
    refute client.approved?
    assert_nil config.auth_token
    assert_empty adapter.posts

    client.send(:check_approval)
    assert client.approved?
    client.flush
    assert_equal [ "log" ], adapter.events.map { |e| e["stream"] }
    assert_equal "Bearer #{ISSUED}", adapter.posts.first[:headers]["Authorization"]
    refute_includes adapter.posts.map { |p| p[:headers]["Authorization"] }, "Bearer #{config.enrollment_key}"
  ensure
    client&.stop
  end

  def test_a_revoked_token_sends_the_app_back_to_asking
    config = enrolling_config
    adapter = EnrollAdapter.new([ "approved" ])
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: adapter))
    client.send(:check_approval)
    assert client.approved?

    client.transport.stub(:fetch_manifest, [ 401, nil, nil ]) { client.send(:refresh_manifest) }
    refute client.approved?
    assert_nil config.issued_token
  ensure
    client&.stop
  end

  def test_a_401_on_an_events_post_drops_the_issued_token_and_asks_again
    config = enrolling_config
    adapter = EnrollAdapter.new([ "approved", "pending" ])
    adapter.instance_variable_get(:@responses).push(401)
    client = Kulla::Client.new(config, transport: Kulla::Transport.new(config, adapter: adapter))
    client.send(:check_approval)
    assert client.approved?

    client.track("log", { "n" => 1 })
    client.flush
    refute client.approved?, "the revoked token is forgotten at once"
    assert_nil config.issued_token
    assert_nil config.auth_token

    assert_equal "pending", client.send(:check_approval)
    assert_equal 2, adapter.enrolls.size, "it asked to join again"
  ensure
    client&.stop
  end

  def test_the_install_key_is_not_a_token
    assert_match(/\Akli_/, enrolling_config.enrollment_key)
    config = Kulla::Configuration.new
    config.env = "production"
    config.endpoint = "https://kulla.example"
    config.enroll = true
    config.instance_variable_set(:@enrollment_key, "kli_#{"k" * 43}")
    assert config.enabled?, "an app waiting to join is enabled"
    assert_nil config.auth_token
  end

  def test_a_placeholder_secret_never_joins
    fake_rails = Module.new do
      def self.application = Struct.new(:secret_key_base).new("x")
    end
    Object.stub_const_for_test(:Rails, fake_rails) do
      config = Kulla::Configuration.new
      config.define_singleton_method(:rails_app?) { true }
      assert_nil config.enrollment_key
    end
  end

  def test_start_bang_starts_an_enabled_sdk_and_ignores_a_disabled_one
    Kulla.instance_variable_set(:@client, nil)
    Kulla.instance_variable_set(:@config, build_config(transport: Kulla::Transport.new(build_config, adapter: FakeAdapter.new)))
    assert Kulla.start!
    assert Kulla.client.worker_alive?
    Kulla.client.stop

    Kulla.instance_variable_set(:@client, nil)
    Kulla.instance_variable_set(:@config, build_config(enabled: false))
    refute Kulla.start!
  ensure
    Kulla.client&.stop
    Kulla.instance_variable_set(:@client, nil)
    Kulla.instance_variable_set(:@config, nil)
  end
end
