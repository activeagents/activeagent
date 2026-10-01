# frozen_string_literal: true

require "digest"

module ActionAgent
  # Estimates LLM spend from token counts. The activeagent gem's telemetry
  # records tokens only; the platform layers pricing on top for the cost
  # figures shown in Traces, Metrics and Evaluations.
  #
  # Rates come from RubyLLM's model registry (USD per million tokens,
  # maintained upstream per model) when the model is known there — looked
  # up under the provider it ran on when the caller knows it, since
  # `gpt-5.5` through OpenRouter and `gpt-5.5` at OpenAI are two entries.
  # The static tables below are the fallback for aliases, self-hosted
  # models and an install without RubyLLM: exact rows (STATIC_RATES) for
  # the current frontier models, then name patterns (PRICES), then a
  # conservative blended rate so totals stay meaningful. Costs are always
  # presented as estimates, and every rate says where it came from
  # (`source`), so a figure worked out at a fallback rate can say so.
  class ModelPricing
    # Exact rates for models the pattern table would otherwise misprice —
    # claude-sonnet-5 is not a $3/$15 Sonnet, and the gpt-5 family is not
    # one price — keyed by the name with its vendor prefix and date suffix
    # removed and its dots and dashes normalised (see .normalize).
    STATIC_RATES = {
      "claude-sonnet-5" => [ 2.00, 10.00 ],
      "gpt-5-5" => [ 5.00, 30.00 ],
      "gpt-5-5-mini" => [ 0.25, 2.00 ],
      "gpt-5-5-nano" => [ 0.05, 0.40 ],
      "gpt-5-1" => [ 1.25, 10.00 ],
      "gpt-5-1-mini" => [ 0.25, 2.00 ],
      "gpt-5-1-nano" => [ 0.05, 0.40 ],
      "gpt-5" => [ 1.25, 10.00 ],
      "gpt-5-mini" => [ 0.25, 2.00 ],
      "gpt-5-nano" => [ 0.05, 0.40 ]
    }.freeze

    PRICES = [
      # [pattern, input $/1M, output $/1M]
      [ /gpt-4o-mini/i, 0.15, 0.60 ],
      [ /gpt-4o/i, 2.50, 10.00 ],
      [ /gpt-4\.1-nano/i, 0.10, 0.40 ],
      [ /gpt-4\.1-mini/i, 0.40, 1.60 ],
      [ /gpt-4\.1/i, 2.00, 8.00 ],
      [ /gpt-5\.?5/i, 5.00, 30.00 ],
      [ /gpt-5(\.\d+)?-nano/i, 0.05, 0.40 ],
      [ /gpt-5(\.\d+)?-mini/i, 0.25, 2.00 ],
      [ /gpt-5/i, 1.25, 10.00 ],
      [ /o3-mini|o4-mini/i, 1.10, 4.40 ],
      [ /claude.*(fable|mythos)/i, 10.00, 50.00 ],
      [ /claude.*haiku-?4/i, 1.00, 5.00 ],
      [ /claude.*(haiku)/i, 0.80, 4.00 ],
      [ /claude.*sonnet-?5/i, 2.00, 10.00 ],
      [ /claude.*(sonnet)/i, 3.00, 15.00 ],
      [ /claude.*opus-(5|4-[5-9])/i, 5.00, 25.00 ],
      [ /claude.*(opus)/i, 15.00, 75.00 ],
      [ /gemini.*flash/i, 0.10, 0.40 ],
      [ /gemini.*pro/i, 1.25, 10.00 ],
      [ /llama|mistral|mixtral|qwen|deepseek/i, 0.20, 0.60 ],
      # Zero-prices "mock-*" traces recorded before the mock fallback was
      # removed, so legacy rows never register as real spend.
      [ /mock/i, 0.0, 0.0 ]
    ].freeze

    # Fallback blended rate for unknown models ($/1M input, $/1M output)
    DEFAULT_RATE = [ 1.00, 4.00 ].freeze

    # Where a rate came from: RubyLLM's bundled catalog, a registry the host
    # keeps itself (RubyLLM's model table or a refreshed listing), a row of
    # STATIC_RATES or PRICES, or DEFAULT_RATE. The last two are a guess at
    # the model's price rather than its listing.
    SOURCES = %w[catalog remote pattern default].freeze
    FALLBACK_SOURCES = %w[pattern default].freeze

    # A gateway's prefix on a model name, which names the provider rather
    # than the model.
    GATEWAY_PREFIXES = %w[openrouter requesty].freeze
    # Vendor prefixes a gateway (or a host) puts before a model name, and
    # the provider the bare name is listed under.
    VENDOR_PROVIDERS = {
      "openai" => "openai", "anthropic" => "anthropic", "google" => "gemini", "gemini" => "gemini",
      "meta-llama" => nil, "mistralai" => "mistral", "mistral" => "mistral", "deepseek" => "deepseek",
      "qwen" => nil, "x-ai" => "xai", "xai" => "xai", "cohere" => nil, "perplexity" => "perplexity"
    }.freeze

    class << self
      # @return [Float, nil] estimated USD cost, nil when there is nothing to price
      def estimate(model:, input_tokens:, output_tokens:, provider: nil)
        estimate_detailed(model: model, input_tokens: input_tokens, output_tokens: output_tokens, provider: provider)&.fetch(:cost)
      end

      # The estimate with its working: `{ cost:, input_rate:, output_rate:,
      # source: }`, rates in $ per million tokens. nil when both token
      # counts are zero — a $0.00 is the caller's to decide on, since
      # nothing generated and nothing recorded look alike here.
      def estimate_detailed(model:, input_tokens:, output_tokens:, provider: nil)
        input = input_tokens.to_i
        output = output_tokens.to_i
        return nil if input.zero? && output.zero?

        rate = rate_detail(model, provider: provider)
        {
          cost: ((input * rate[:input]) + (output * rate[:output])) / 1_000_000.0,
          input_rate: rate[:input],
          output_rate: rate[:output],
          source: rate[:source]
        }
      end

      # @return [Array(Float, Float)] input and output rates in $ per million tokens
      def rate_for(model, provider = nil)
        rate = rate_detail(model, provider: provider)
        [ rate[:input], rate[:output] ]
      end

      # `{ input:, output:, source: }` for a model under a provider, memoized
      # per [provider, model]: the registry scan is not free and trace
      # serialization asks per row.
      def rate_detail(model, provider: nil)
        return { input: DEFAULT_RATE[0], output: DEFAULT_RATE[1], source: "default" } if model.blank?

        key = [ provider.to_s, model.to_s ]
        @rates ||= {}
        return @rates[key] if @rates.key?(key)

        @rates[key] = registry_rate(model.to_s, provider.to_s.presence) || static_rate(model.to_s)
      end

      # Forgets memoized rates — after RubyLLM is loaded, or in tests.
      def reset!
        @rates = {}
      end

      # Names the rate tables in force, so a cache of figures worked out at
      # them is invalidated when they change: the static rows, the default,
      # and the version of the registry the install has (or none).
      def fingerprint
        registry = defined?(::RubyLLM) && ::RubyLLM.const_defined?(:VERSION) ? ::RubyLLM::VERSION.to_s : "none"
        tables = [ STATIC_RATES, PRICES.map { |pattern, input, output| [ pattern.source, input, output ] }, DEFAULT_RATE, registry ]
        Digest::SHA256.hexdigest(JSON.generate(tables))[0, 12]
      end

      # "openrouter/anthropic/claude-sonnet-4-5-20250929" → "claude-sonnet-4-5":
      # the name without a gateway or vendor prefix, a date suffix or a
      # colon-tagged size, with dots as dashes, so the same model under two
      # spellings keys one row.
      def normalize(model)
        name = model.to_s.strip.downcase
        name = name.split("/").last.to_s
        name = name.sub(/-\d{8}\z/, "").sub(/-\d{4}-\d{2}-\d{2}\z/, "")
        name.tr(".", "-")
      end

      private

      # The registry's rate for the first spelling it knows: the name as
      # given under the provider it ran on, then bare, then with a gateway
      # or vendor prefix stripped (under the vendor's own provider), each
      # with its dots and dashes swapped and its date suffix dropped.
      def registry_rate(model, provider)
        return nil unless registry_available?

        lookup_candidates(model, provider).each do |id, candidate_provider|
          info = registry_find(id, candidate_provider)
          tokens = info&.pricing&.text_tokens
          next unless tokens.respond_to?(:input) && tokens.input && tokens.output

          return { input: tokens.input.to_f, output: tokens.output.to_f, source: registry_source }
        end
        nil
      rescue StandardError
        nil
      end

      def registry_available?
        defined?(::RubyLLM) && ::RubyLLM.respond_to?(:models)
      end

      # A host that keeps its own model registry (RubyLLM's model table or
      # a refreshed listing) prices from it rather than from the gem's
      # bundled catalog.
      def registry_source
        config = ::RubyLLM.respond_to?(:config) ? ::RubyLLM.config : nil
        return "remote" if config.respond_to?(:model_registry_class) && config.model_registry_class.present?

        "catalog"
      end

      # RubyLLM 2 takes the provider as a keyword; 1.x took it positionally.
      def registry_find(id, provider)
        models = ::RubyLLM.models
        return models.find(id) if provider.blank?

        if registry_find_keyword?(models)
          models.find(id, provider: provider)
        else
          models.find(id, provider)
        end
      rescue StandardError
        nil
      end

      def registry_find_keyword?(models)
        models.method(:find).parameters.any? { |type, name| name == :provider && %i[key keyreq].include?(type) }
      end

      # [[id, provider], ...] to try in order, without repeats.
      def lookup_candidates(model, provider)
        name = model.strip
        provider = provider&.downcase
        candidates = []

        head, rest = name.split("/", 2)
        if rest.present? && GATEWAY_PREFIXES.include?(head.downcase)
          provider ||= head.downcase
          name = rest
          head, rest = name.split("/", 2)
        end

        names = [ name ]
        if rest.present? && VENDOR_PROVIDERS.key?(head.downcase)
          names << rest
          vendor_provider = VENDOR_PROVIDERS[head.downcase]
        end

        names.each do |candidate|
          spellings(candidate).each do |spelling|
            candidates << [ spelling, provider ] if provider
            candidates << [ spelling, vendor_provider ] if vendor_provider && vendor_provider != provider && candidate == rest
            candidates << [ spelling, nil ]
          end
        end
        candidates.uniq
      end

      # The name as given, then with its date suffix dropped, each with its
      # dots and dashes swapped: "claude-sonnet-4.5" and "claude-sonnet-4-5"
      # are one model.
      def spellings(name)
        undated = name.sub(/-\d{8}\z/, "").sub(/-\d{4}-\d{2}-\d{2}\z/, "")
        [ name, undated ].uniq.flat_map do |spelling|
          [ spelling, spelling.gsub(/(\d)\.(\d)/, '\1-\2'), spelling.gsub(/(\d)-(\d)/, '\1.\2') ]
        end.uniq
      end

      # An exact row for the normalised name, else the first pattern the
      # name as given matches, else the default.
      def static_rate(model)
        if (exact = STATIC_RATES[normalize(model)])
          return { input: exact[0], output: exact[1], source: "pattern" }
        end

        PRICES.each do |pattern, input_rate, output_rate|
          return { input: input_rate, output: output_rate, source: "pattern" } if model.match?(pattern)
        end
        { input: DEFAULT_RATE[0], output: DEFAULT_RATE[1], source: "default" }
      end
    end
  end
end
