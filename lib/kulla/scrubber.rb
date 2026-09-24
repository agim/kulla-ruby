module Kulla
  # Turns arbitrary attrs into JSON-safe data and removes secrets.
  #
  # With filter: true (the default), keys matching the app's filter_parameters become "[FILTERED]"
  # and credential-looking keys (authorization, cookie, password, secret, token...) are removed.
  # With filter: false the data is only made JSON-safe; the SDK uses that for attrs it builds itself
  # from fixed field names (e.g. deploy gem names, which "bcrypt" would otherwise trip).
  class Scrubber
    FILTERED = "[FILTERED]".freeze
    TRUNCATED = "[TRUNCATED]".freeze
    ALWAYS_DROP = /(?:\A|_)(?:authorization|cookies?|set_cookie|password|passwd|secrets?|tokens?)(?:_|\z)/
    MAX_DEPTH = 6
    MAX_ITEMS = 500
    MAX_STRING_BYTES = 8_192

    def initialize(filters = [])
      @key_filter, @path_filter = compile(Array(filters))
    end

    def call(attrs, filter: true)
      attrs = { "value" => attrs } unless attrs.is_a?(Hash)
      sanitize(attrs, 0, nil, filter)
    end

    def filtered_key?(key, path = key)
      (@key_filter && @key_filter.match?(key)) || (@path_filter && @path_filter.match?(path)) || false
    end

    def self.drop_key?(key)
      ALWAYS_DROP.match?(key.downcase.tr("-", "_"))
    end

    def self.clean_string(value, max_bytes = MAX_STRING_BYTES)
      string = value.to_s
      string = string.dup.force_encoding(Encoding::UTF_8) unless string.encoding == Encoding::UTF_8
      string = string.scrub("?") unless string.valid_encoding?
      string = string.byteslice(0, max_bytes).scrub("") if string.bytesize > max_bytes
      string
    end

    private
      def sanitize(value, depth, path, filter)
        case value
        when Hash then sanitize_hash(value, depth, path, filter)
        when Array, Set then sanitize_array(value.to_a, depth, path, filter)
        when String then self.class.clean_string(value)
        when Symbol then value.to_s
        when Integer, true, false, nil then value
        when Float then value.finite? ? value : value.to_s
        when Numeric then value.to_f
        when Time then value.utc.iso8601(3)
        when Exception then "#{value.class}: #{self.class.clean_string(value.message, 1024)}"
        else describe(value)
        end
      end

      def sanitize_hash(hash, depth, path, filter)
        return TRUNCATED if depth >= MAX_DEPTH

        hash.first(MAX_ITEMS).each_with_object({}) do |(key, value), out|
          key = self.class.clean_string(key, 256)
          next if filter && self.class.drop_key?(key)

          full_path = path ? "#{path}.#{key}" : key
          out[key] = filter && filtered_key?(key, full_path) ? FILTERED : sanitize(value, depth + 1, full_path, filter)
        end
      end

      def sanitize_array(array, depth, path, filter)
        return TRUNCATED if depth >= MAX_DEPTH
        array.first(MAX_ITEMS).map { |item| sanitize(item, depth + 1, path, filter) }
      end

      # Never call to_json/as_json on unknown objects: an ActiveRecord model would serialize every column.
      def describe(value)
        if value.respond_to?(:iso8601) then value.iso8601
        elsif defined?(ActiveRecord::Base) && value.is_a?(ActiveRecord::Base) then "#{value.class.name}##{value.id}"
        else self.class.clean_string(value.to_s, 1024)
        end
      rescue StandardError
        value.class.name.to_s
      end

      # Mirrors Rails' ParameterFilter: strings/symbols match keys partially and case-insensitively,
      # strings containing a dot match the full nested path, regexps are used as given.
      def compile(filters)
        keys = []
        paths = []
        filters.each do |filter|
          case filter
          when Regexp then (filter.source.include?("\\.") ? paths : keys) << filter
          when String, Symbol
            string = filter.to_s
            next if string.empty?
            (string.include?(".") ? paths : keys) << Regexp.new(Regexp.escape(string), Regexp::IGNORECASE)
          end
        end
        [ keys.empty? ? nil : Regexp.union(keys), paths.empty? ? nil : Regexp.union(paths) ]
      end
  end
end
