require "test_helper"

class ScrubberTest < Minitest::Test
  def scrub(attrs, filters: [], filter: true)
    Kulla::Scrubber.new(filters).call(attrs, filter: filter)
  end

  def test_filter_parameters_match_partially_and_case_insensitively
    out = scrub({ "Email" => "a@b.c", "user" => { "passw_hint" => "x", "name" => "Ann" } }, filters: [ :email, "passw" ])

    assert_equal "[FILTERED]", out["Email"]
    assert_equal "[FILTERED]", out["user"]["passw_hint"]
    assert_equal "Ann", out["user"]["name"]
  end

  def test_regexp_and_dotted_filters
    out = scrub({ "card" => { "code" => "123", "brand" => "visa" }, "ssn_last" => "1" },
                filters: [ "card.code", /\Assn/ ])

    assert_equal({ "code" => "[FILTERED]", "brand" => "visa" }, out["card"])
    assert_equal "[FILTERED]", out["ssn_last"]
  end

  def test_filters_inside_arrays
    out = scrub({ "items" => [ { "email" => "x" }, { "email" => "y" } ] }, filters: [ :email ])
    assert_equal [ { "email" => "[FILTERED]" } ] * 2, out["items"]
  end

  def test_always_drops_credential_keys
    attrs = {
      "Authorization" => "Bearer x", "HTTP_COOKIE" => "a=b", "Set-Cookie" => "c", "password" => "p",
      "password_confirmation" => "p", "client_secret" => "s", "api_token" => "t", "tokenizer" => "keep",
      "nested" => { "access_token" => "t", "ok" => 1 }
    }
    out = scrub(attrs)

    assert_equal({ "tokenizer" => "keep", "nested" => { "ok" => 1 } }, out)
  end

  def test_filter_false_keeps_keys_but_still_makes_json_safe
    out = scrub({ gems: { "bcrypt" => "3.1" }, token: :abc }, filters: [ :crypt ], filter: false)
    assert_equal({ "gems" => { "bcrypt" => "3.1" }, "token" => "abc" }, out)
  end

  def test_values_become_json_safe
    custom = Object.new
    def custom.to_s = "custom!"
    out = scrub({
      sym: :x, nan: Float::NAN, time: Time.utc(2026, 9, 24, 10, 2, 11.482r), obj: custom,
      bad: "caf\xC3".b, big: "x" * 10_000, rational: 1/3r, error: ArgumentError.new("nope")
    })

    assert_equal "x", out["sym"]
    assert_equal "NaN", out["nan"]
    assert_equal "2026-09-24T10:02:11.482Z", out["time"]
    assert_equal "custom!", out["obj"]
    assert out["bad"].valid_encoding?
    assert_equal 8_192, out["big"].bytesize
    assert_in_delta 0.333, out["rational"], 0.001
    assert_equal "ArgumentError: nope", out["error"]
    JSON.generate(out)
  end

  def test_depth_is_limited_and_cycles_terminate
    deep = { "a" => { "b" => { "c" => { "d" => { "e" => { "f" => { "g" => 1 } } } } } } }
    out = scrub(deep)
    assert_equal "[TRUNCATED]", out.dig("a", "b", "c", "d", "e", "f")

    cyclic = {}
    cyclic["self"] = cyclic
    JSON.generate(scrub(cyclic))
  end

  def test_non_hash_attrs_are_wrapped
    assert_equal({ "value" => "hello" }, scrub("hello"))
  end
end
