require "test_helper"

class EventTest < Minitest::Test
  include KullaTestHelpers

  def test_normalizes_stream_names
    {
      "user.signup" => "user.signup",
      "User Signup!" => "user_signup_",
      "Billing::Invoice.paid" => "billing__invoice.paid",
      "123abc" => "e123abc",
      "_private" => "e_private",
      ".leading..dots." => "leading.dots",
      :"order.Created" => "order.created"
    }.each do |input, expected|
      assert_equal expected, Kulla::Event.normalize_stream(input), input.inspect
    end
  end

  def test_normalized_names_always_match_the_contract
    [ "a" * 100, "x.#{"y" * 70}", "émoji 🎉 event", "a.b.c.d", "UPPER.Case-Name" ].each do |input|
      name = Kulla::Event.normalize_stream(input)
      assert_match Kulla::Event::STREAM_FORMAT, name
      assert_operator name.length, :<=, 64
    end
  end

  def test_unusable_names_return_nil
    assert_nil Kulla::Event.normalize_stream("")
    assert_nil Kulla::Event.normalize_stream("...")
  end

  def test_levels
    assert_equal "warn", Kulla::Event.normalize_level(:warning)
    assert_equal "error", Kulla::Event.normalize_level("ERROR")
    assert_equal "info", Kulla::Event.normalize_level(:bogus)
  end

  def test_timestamps
    assert_equal "2025-02-07T21:47:23.208Z", Kulla::Event.format_ts(1_738_964_843_208_679_035)
    assert_equal "2026-09-24T10:02:11.482Z", Kulla::Event.format_ts(Time.utc(2026, 9, 24, 10, 2, 11.482r))
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, Kulla::Event.format_ts(nil))
  end

  def test_build_envelope
    event = Kulla::Event.build("Mail", { "status" => "sent" }, config: build_config, level: :warning,
                               message: "m" * 10_000, trace: "req-1")

    assert_equal "mail", event["stream"]
    assert_equal "production", event["env"]
    assert_equal "test-host", event["host"]
    assert_equal "abc1234", event["release"]
    assert_equal "req-1", event["trace"]
    assert_equal "warn", event["level"]
    assert_equal 8_192, event["message"].bytesize
    assert_equal({ "status" => "sent" }, event["attrs"])
    refute event.key?("app")
  end
end
