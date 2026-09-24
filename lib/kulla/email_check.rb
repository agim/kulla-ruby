require "resolv"

module Kulla
  # Kulla.email_valid?(address): a syntax check plus a DNS check that the domain can receive mail (MX,
  # else A/AAAA; a null MX means no), cached per domain for an hour. An address whose domain can't
  # receive mail is reported as an `email.invalid` signal, active at once for every app, and an address
  # Kulla already knows as invalid is refused without a lookup. A resolver failure counts as valid, so
  # DNS trouble never blocks a signup. Never raises.
  module EmailCheck
    CACHE_TTL = 3600
    MAX_CACHE = 10_000
    TIMEOUT = 2
    FORMAT = /\A[^@\s]+@([^@\s]+\.[^@\s]+)\z/

    @cache = {}
    @mutex = Mutex.new

    module_function

    def valid?(address, client: nil)
      address = address.to_s.strip
      domain = address[FORMAT, 1]&.downcase or return false
      client ||= Kulla.client
      live = client.config.enabled?
      return false if live && client.signal?("email.invalid", address)

      ok = deliverable?(domain)
      client.report_signal("email.invalid", address, reason: "no mail server for #{domain}") if !ok && live
      ok
    rescue StandardError => e
      Kulla.log("email check failed: #{e.class}: #{e.message}")
      true
    end

    def deliverable?(domain)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cached = @mutex.synchronize { @cache[domain] }
      return cached[0] if cached && cached[1] > now

      result = resolve(domain)
      @mutex.synchronize do
        @cache.shift if @cache.size >= MAX_CACHE
        @cache[domain] = [ result, now + CACHE_TTL ]
      end
      result
    end

    def resolve(domain)
      Resolv::DNS.open do |dns|
        dns.timeouts = TIMEOUT
        mx = dns.getresources(domain, Resolv::DNS::Resource::IN::MX)
        return mx.any? { |r| r.exchange.to_s != "" } if mx.any?
        dns.getresources(domain, Resolv::DNS::Resource::IN::A).any? || dns.getresources(domain, Resolv::DNS::Resource::IN::AAAA).any?
      end
    rescue Resolv::ResolvError, Resolv::ResolvTimeout, StandardError
      true
    end

    def reset! = @mutex.synchronize { @cache.clear }
  end
end
