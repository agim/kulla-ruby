module Kulla
  # Builds the event envelope described in docs/api.md.
  module Event
    STREAM_FORMAT = /\A[a-z][a-z0-9_]*(\.[a-z0-9_]+)*\z/
    MAX_STREAM_LENGTH = 64
    MAX_MESSAGE_BYTES = 8_192
    LEVELS = %w[debug info warn error fatal].freeze
    LEVEL_ALIASES = { "warning" => "warn", "critical" => "fatal", "notice" => "info" }.freeze

    module_function

    def build(stream, attrs, config:, level: :info, message: nil, trace: nil, ts: nil)
      name = normalize_stream(stream)
      return if name.nil?

      {
        "stream" => name,
        "ts" => format_ts(ts),
        "env" => config.env,
        "host" => config.host,
        "release" => config.release,
        "trace" => trace.nil? ? nil : Scrubber.clean_string(trace, 256),
        "level" => normalize_level(level),
        "message" => message.nil? ? nil : Scrubber.clean_string(message, MAX_MESSAGE_BYTES),
        "attrs" => attrs
      }.compact
    end

    # "User Signup!" -> "user_signup_", "Billing::Invoice.paid" -> "billing__invoice.paid",
    # "123abc" -> "e123abc". Returns nil when nothing usable is left.
    def normalize_stream(name)
      stream = name.to_s.downcase.gsub(/[^a-z0-9_.]/, "_")
      stream = stream.squeeze(".").delete_prefix(".")
      return if stream.empty?

      stream = "e#{stream}" unless stream.match?(/\A[a-z]/)
      stream = stream[0, MAX_STREAM_LENGTH].sub(/\.+\z/, "")
      stream.match?(STREAM_FORMAT) ? stream : nil
    end

    def normalize_level(level)
      level = level.to_s.downcase
      level = LEVEL_ALIASES.fetch(level, level)
      LEVELS.include?(level) ? level : "info"
    end

    # Accepts a Time, nanoseconds since the epoch (Rails.event timestamps), an ISO 8601 string or nil.
    def format_ts(ts)
      time =
        case ts
        when nil then Time.now
        when Time then ts
        when Integer then Time.at(0, ts, :nanosecond)
        when Float then Time.at(ts / 1_000_000_000.0)
        when String then return ts
        else ts.respond_to?(:to_time) ? ts.to_time : Time.now
        end
      time.utc.iso8601(3)
    end
  end
end
