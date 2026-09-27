module Kulla
  module Subscribers
    # RubyLLM completions -> `llm`: provider, model, tokens, duration, cost when the model registry
    # knows the price. Prompts and replies are never sent.
    module Llm
      module Patch
        def complete(...)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          message = super
          Llm.record(self, message, started, nil)
          message
        rescue StandardError => e
          Llm.record(self, nil, started, e)
          raise
        end
      end

      module_function

      def install
        return unless defined?(::RubyLLM::Chat)
        ::RubyLLM::Chat.prepend(Patch) unless ::RubyLLM::Chat.ancestors.include?(Patch)
      end

      def record(chat, message, started, error)
        client = Kulla.client
        return unless client.config.enabled? && client.config.capture?(:llm)

        model = chat.respond_to?(:model) ? chat.model : nil
        input = tokens(message, :input)
        output = tokens(message, :output)
        attrs = {
          "provider" => (model.respond_to?(:provider) ? model.provider : nil)&.to_s,
          "model" => model_id(message) || (model.respond_to?(:id) ? model.id : nil),
          "input_tokens" => input, "output_tokens" => output,
          "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1),
          "cost_usd" => cost(model, input, output), "error" => error&.class&.name
        }.compact
        ctx = Context.current
        ctx&.breadcrumb("llm", "#{attrs["model"]} #{input}→#{output} tokens", duration_ms: attrs["duration_ms"])
        client.track("llm", attrs, trace: ctx&.trace, level: error ? :error : :info, scrub: false)
      rescue StandardError => e
        Kulla.log("llm capture failed: #{e.class}: #{e.message}")
      end

      def cost(model, input, output)
        return unless input && output
        inp = price(model, :input) or return
        out = price(model, :output) or return
        ((input * inp + output * out) / 1_000_000.0).round(6)
      end

      # RubyLLM 1.x: message.input_tokens / output_tokens; 2.x: message.tokens.input / .output.
      def tokens(message, kind)
        return message.public_send(:"#{kind}_tokens") if message.respond_to?(:"#{kind}_tokens")
        counts = message.respond_to?(:tokens) ? message.tokens : nil
        counts.respond_to?(kind) ? counts.public_send(kind) : nil
      rescue StandardError
        nil
      end

      # RubyLLM 1.x: message.model_id; 2.x: message.model is the id string.
      def model_id(message)
        return message.model_id if message.respond_to?(:model_id) && message.model_id
        id = message.respond_to?(:model) ? message.model : nil
        id.is_a?(String) ? id : nil
      end

      # RubyLLM 1.x: input_price_per_million; 2.x: pricing.text_tokens.standard.input_per_million.
      def price(model, side)
        return model.public_send("#{side}_price_per_million")&.to_f if model.respond_to?("#{side}_price_per_million")
        standard = model.pricing.text_tokens.standard if model.respond_to?(:pricing)
        standard&.public_send("#{side}_per_million")&.to_f
      rescue StandardError
        nil
      end
    end
  end
end
