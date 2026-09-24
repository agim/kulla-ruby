module Kulla
  # ActionMailer interceptor (opt-in: `c.suppress_bad_emails = true`). Removes To/Cc/Bcc
  # recipients with an active `email.bounced` or `email.complaint` signal, and cancels the
  # delivery (perform_deliveries = false) when nobody is left. Addresses are matched by hash;
  # the log shows counts and masked addresses only.
  class MailInterceptor
    KINDS = %w[email.bounced email.complaint].freeze
    FIELDS = %i[to cc bcc].freeze

    class << self
      def delivering_email(message, client: nil)
        client ||= Kulla.client
        return unless client.config.suppress_bad_emails

        removed = []
        FIELDS.each do |field|
          next unless message.respond_to?(field) && message.respond_to?("#{field}=")

          recipients = Array(message.public_send(field))
          next if recipients.empty?

          kept = recipients.reject { |address| suppressed?(client, address) && removed << address }
          message.public_send("#{field}=", kept.empty? ? nil : kept) if kept.size != recipients.size
        end
        return if removed.empty?

        masked = removed.map { |address| mask(address) }.join(", ")
        if FIELDS.all? { |field| !message.respond_to?(field) || Array(message.public_send(field)).empty? }
          message.perform_deliveries = false
          Kulla.log("cancelled a delivery: every recipient has a bounce/complaint signal (#{masked})", level: :info)
        else
          Kulla.log("removed #{removed.size} recipient(s) with a bounce/complaint signal (#{masked})", level: :info)
        end
      rescue StandardError => e
        Kulla.log("mail interceptor failed: #{e.class}: #{e.message}")
      end

      def suppressed?(client, address)
        email = address.to_s[/<([^>]+)>/, 1] || address.to_s
        KINDS.any? { |kind| client.signal?(kind, email) }
      end

      private
        def mask(address)
          name, domain = address.to_s.strip.split("@", 2)
          domain ? "#{name.to_s[0, 1]}***@#{domain}" : "***"
        end
    end
  end
end
