require "json"
require "time"
require "socket"
require "zlib"
require "stringio"
require "digest"
require "securerandom"
require "openssl"

require_relative "kulla/version"
require_relative "kulla/configuration"
require_relative "kulla/context"
require_relative "kulla/scrubber"
require_relative "kulla/event"
require_relative "kulla/buffer"
require_relative "kulla/signal_store"
require_relative "kulla/transport"
require_relative "kulla/client"
require_relative "kulla/fork_hook"
require_relative "kulla/visit_endpoint"
require_relative "kulla/signal_blocker"
require_relative "kulla/mail_interceptor"
require_relative "kulla/email_check"
require_relative "kulla/webhook"
require_relative "kulla/helper"
require_relative "kulla/subscribers/errors"
require_relative "kulla/subscribers/requests"
require_relative "kulla/subscribers/jobs"
require_relative "kulla/subscribers/mail"
require_relative "kulla/subscribers/security"
require_relative "kulla/subscribers/events"
require_relative "kulla/subscribers/deploy"
require_relative "kulla/subscribers/heartbeat"
require_relative "kulla/subscribers/sql"
require_relative "kulla/subscribers/http"
require_relative "kulla/subscribers/llm"
require_relative "kulla/subscribers/logs"

module Kulla
  @lock = Mutex.new

  class << self
    def config
      @config || @lock.synchronize { @config ||= Configuration.new }
    end

    def configure
      yield config
      config.reset_scrubber!
      config
    rescue StandardError => e
      log("configure failed: #{e.class}: #{e.message}")
      config
    end

    def client
      @client || @lock.synchronize { @client ||= Client.new(config) }
    end

    # Send a custom event. The stream name is normalized to Kulla's stream format.
    def track(stream, attrs = {}, level: :info, message: nil)
      client.track(stream, attrs, level: level, message: message)
    rescue StandardError => e
      log("track failed: #{e.class}: #{e.message}")
      nil
    end

    def error(exception, context = {})
      client.error(exception, context: context, handled: true, severity: :error, source: "application")
    rescue StandardError => e
      log("error failed: #{e.class}: #{e.message}")
      nil
    end

    # True when Kulla has an active signal of this kind for the subject, e.g.
    # Kulla.signal?("email.bounced", user.email) or Kulla.signal?("ip.blocked", request.remote_ip).
    # Answers from the in-memory copy the worker keeps in sync (every 60 s); false until then.
    def signal?(kind, subject)
      client.signal?(kind, subject)
    rescue StandardError => e
      log("signal? failed: #{e.class}: #{e.message}")
      false
    end

    # Kulla.email_valid?("x@example.com"): syntax + can the domain receive mail (DNS), sharing invalid
    # addresses with every app as email.invalid signals. See EmailCheck.
    def email_valid?(address)
      EmailCheck.valid?(address)
    end

    # Tell Kulla what this app saw: Kulla.report_signal("ip.blocked", ip, reason: "wp-login scan").
    # Queued and sent by the worker; never raises. Returns true when queued.
    def report_signal(kind, subject, reason: nil, details: {})
      client.report_signal(kind, subject, reason: reason, details: details)
    rescue StandardError => e
      log("report_signal failed: #{e.class}: #{e.message}")
      false
    end

    # Starts reporting from a long-running process that Rails doesn't treat as a server or job worker,
    # such as a daemon run as a rake task. The Railtie already starts web servers and job processes and
    # skips rake, console and one-off commands; call this once, after the app has loaded, in a process
    # that should report anyway. It joins like any other process of the app (same install key), so an
    # approved app needs no new approval. Returns true when it started.
    def start!(role: "task")
      return false unless config.enabled?

      config.process_role ||= role.to_s
      Railtie.install_subscribers(client, config) if defined?(Railtie)
      client.start
      true
    rescue StandardError => e
      log("start! failed: #{e.class}: #{e.message}")
      false
    end

    # A security event the app knows about (a failed login, a blocked signup):
    #   Kulla.security("login_failed", ip: request.remote_ip, path: request.path)
    def security(rule, ip: nil, **attrs)
      return unless config.enabled? && config.capture?(:security)
      client.track("security", { "rule" => rule.to_s, "match_type" => "app", "ip" => ip }.compact.merge(attrs.transform_keys(&:to_s)), level: :warn)
    rescue StandardError => e
      log("security failed: #{e.class}: #{e.message}")
      nil
    end

    def flush
      @client&.flush
      nil
    rescue StandardError => e
      log("flush failed: #{e.class}: #{e.message}")
      nil
    end

    def shutdown
      @client&.shutdown
      nil
    rescue StandardError => e
      log("shutdown failed: #{e.class}: #{e.message}")
      nil
    end

    def after_fork
      @client&.after_fork
    rescue StandardError => e
      log("after_fork failed: #{e.class}: #{e.message}")
    end

    def register_at_exit
      @lock.synchronize do
        return if @at_exit_registered
        @at_exit_registered = true
      end
      at_exit { shutdown }
    end

    def log(message, level: :debug)
      logger = config.logger
      logger&.public_send(level, "[kulla] #{message}")
    rescue StandardError
      nil
    end

    # Test helper: forget the client and configuration.
    def reset!
      client = @client
      @client = nil
      @config = nil
      client&.stop
    end
  end
end

require_relative "kulla/railtie" if defined?(Rails::Railtie)
