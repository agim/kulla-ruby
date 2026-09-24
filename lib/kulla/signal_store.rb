require "ipaddr"

module Kulla
  # In-memory copy of Kulla's active signals (docs/api.md, "Signals"), filled by the worker's poll
  # of GET /api/v1/signals. Thread-safe. Starts empty on boot and syncs from scratch.
  #
  # Emails never leave Kulla, so email kinds are matched on subject_hash: the SHA-256 of the
  # trimmed, lowercased address. Every other kind is matched on the subject (IPs normalized with
  # IPAddr, domains lowercased), the same normalization Kulla applies.
  class SignalStore
    ACTIVE = "active".freeze

    attr_reader :cursor

    def initialize
      @mutex = Mutex.new
      @entries = Hash.new { |hash, kind| hash[kind] = {} } # kind => { key => expires_at (Time) or nil }
      @cursor = nil
    end

    def self.email_kind?(kind)
      kind.to_s.start_with?("email.")
    end

    def self.hash_email(address)
      Digest::SHA256.hexdigest(address.to_s.strip.downcase)
    end

    # The key a subject is stored under for its kind.
    def self.key_for(kind, subject)
      kind = kind.to_s
      text = subject.to_s.strip
      if email_kind?(kind) then hash_email(text)
      elsif kind.start_with?("ip.") then normalize_ip(text)
      elsif kind.start_with?("domain.") then text.downcase
      else text
      end
    end

    def self.normalize_ip(text)
      IPAddr.new(text).to_s
    rescue IPAddr::Error, ArgumentError
      text
    end

    def active?(kind, subject)
      return false if subject.nil? || subject.to_s.strip.empty?

      key = self.class.key_for(kind, subject)
      @mutex.synchronize do
        return false unless @entries.key?(kind.to_s)
        entries = @entries[kind.to_s]
        return false unless entries.key?(key)

        expires_at = entries[key]
        return true if expires_at.nil? || expires_at > Time.now

        # Expiry doesn't change updated_at, so the feed never announces it; drop it here.
        entries.delete(key)
        false
      end
    end

    # Applies one page of GET /api/v1/signals and moves the cursor. Returns the number applied.
    def apply_page(page)
      signals = Array(page["signals"])
      @mutex.synchronize do
        applied = signals.count { |signal| apply_locked(signal) }
        cursor = page["cursor"].to_s
        @cursor = cursor unless cursor.empty?
        applied
      end
    end

    def apply(signal)
      @mutex.synchronize { apply_locked(signal) }
    end

    def size(kind = nil)
      @mutex.synchronize { kind ? (@entries.key?(kind.to_s) ? @entries[kind.to_s].size : 0) : @entries.sum { |_, e| e.size } }
    end

    def clear
      @mutex.synchronize do
        @entries.clear
        @cursor = nil
      end
    end

    private
      def apply_locked(signal)
        return false unless signal.is_a?(Hash)
        kind = signal["kind"].to_s
        return false if kind.empty?

        key = entry_key(kind, signal)
        return false if key.nil?

        expires_at = parse_time(signal["expires_at"])
        if signal["state"] == ACTIVE && (expires_at.nil? || expires_at > Time.now)
          @entries[kind][key] = expires_at
        elsif @entries.key?(kind)
          @entries[kind].delete(key)
        end
        true
      end

      def entry_key(kind, signal)
        if self.class.email_kind?(kind)
          hash = signal["subject_hash"].to_s.downcase
          hash.empty? ? nil : hash
        else
          subject = signal["subject"].to_s.strip
          subject.empty? ? nil : self.class.key_for(kind, subject)
        end
      end

      def parse_time(value)
        return if value.nil? || value.to_s.empty?
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
  end
end
