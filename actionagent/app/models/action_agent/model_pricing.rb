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
  # `gpt-5.5` through OpenRouter and `gpt-5.5` at OpenAI are two entries,
  # and `deepseek-v4-flash` through Ollama Cloud is priced by Ollama, not
  # by DeepSeek. A model run under Ollama is looked up in the registry's
  # Ollama Cloud listing by the name the cloud uses, whichever way it was
  # spelled (`gpt-oss:120b-cloud` through a local server is the cloud's
  # `gpt-oss:120b`). The static tables below are the fallback for aliases,
  # self-hosted models and an install without RubyLLM: exact rows
  # (STATIC_RATES) for the current frontier models and Ollama Cloud's own
  # price list (OLLAMA_CLOUD_RATES), then name patterns (PRICES), then a
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

    # Ollama Cloud's price list, by the name the cloud lists each model
    # under: USD per million input and output tokens. The rows RubyLLM's
    # registry carries under its `ollama_cloud` provider (RubyLLM 2.1.1,
    # from models.dev), copied on 2026-10-30 for an install without the
    # gem; DeepSeek's rows are its off-peak rates. A model the cloud lists
    # at no price yet is left out, so it prices as any other Ollama model.
    OLLAMA_CLOUD_RATES = {
      "deepseek-v4-flash" => [ 0.22, 0.66 ],
      "deepseek-v4-flash:0731" => [ 0.22, 0.66 ],
      "deepseek-v4-pro" => [ 0.66, 1.98 ],
      "deepseek-v4-pro:0813" => [ 0.66, 1.98 ],
      "deepseek-v4.1-flash" => [ 0.15, 0.60 ],
      "gemma4:31b" => [ 0.14, 0.40 ],
      "glm-5.1" => [ 1.00, 3.20 ],
      "glm-5.2" => [ 1.40, 4.40 ],
      "glm-5.3" => [ 1.40, 4.40 ],
      "glm-5.3-flash" => [ 0.15, 0.50 ],
      "gpt-oss:120b" => [ 0.15, 0.60 ],
      "gpt-oss:20b" => [ 0.07, 0.30 ],
      "kimi-k2.6" => [ 0.95, 4.00 ],
      "kimi-k2.7-code" => [ 0.95, 4.00 ],
      "kimi-k3" => [ 3.00, 15.00 ],
      "minimax-m2.7" => [ 0.30, 1.20 ],
      "minimax-m3" => [ 0.60, 2.40 ],
      "mistral-large-3:675b" => [ 0.50, 1.50 ],
      "nemotron-3-nano:30b" => [ 0.06, 0.24 ],
      "nemotron-3-super" => [ 0.015, 0.60 ],
      "nemotron-3-ultra" => [ 0.10, 3.00 ],
      "qwen3.5:397b" => [ 0.60, 3.60 ]
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

    # Where a rate came from: a listing of the model — RubyLLM's bundled
    # catalog, or Ollama Cloud's price list bundled here (`catalog`), or a
    # registry the host keeps itself, RubyLLM's model table or a refreshed
    # listing (`remote`) — else a row of STATIC_RATES or PRICES, or
    # DEFAULT_RATE. The last two are a guess at the model's price rather
    # than its listing.
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

    # Provider names as the registry spells them, for the ones a trace's
    # `llm.provider` tag ("OpenAI::Chat", "Ollama") or a run's provider key
    # ("open_router") spells otherwise once downcased and cut at "::".
    PROVIDER_SLUGS = {
      "open_router" => "openrouter", "open_ai" => "openai", "ollama-cloud" => "ollama_cloud",
      "azure_openai" => "azure", "azureopenai" => "azure", "azure_open_ai" => "azure"
    }.freeze

    # The registry's provider for Ollama Cloud's listing, which prices a
    # model run under Ollama whichever route served it.
    OLLAMA_CLOUD_PROVIDER = "ollama_cloud"
    OLLAMA_PROVIDERS = [ "ollama", OLLAMA_CLOUD_PROVIDER ].freeze
    # A local Ollama server's spellings of a cloud model: the framework's
    # ActiveAgent::Providers::Ollama::Cloud, kept in step.
    OLLAMA_CLOUD_MARKERS = %w[-cloud :cloud].freeze

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

        slug = provider_slug(provider)
        key = [ slug.to_s, model.to_s ]
        @rates ||= {}
        return @rates[key] if @rates.key?(key)

        @rates[key] = registry_rate(model.to_s, slug) || static_rate(model.to_s, slug)
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
        tables = [
          STATIC_RATES, OLLAMA_CLOUD_RATES, PRICES.map { |pattern, input, output| [ pattern.source, input, output ] },
          DEFAULT_RATE, registry
        ]
        Digest::SHA256.hexdigest(JSON.generate(tables))[0, 12]
      end

      # "openrouter/anthropic/claude-sonnet-4-5-20250929" → "claude-sonnet-4-5",
      # "gpt-oss:120b-cloud" → "gpt-oss:120b": the name without a gateway or
      # vendor prefix, a date suffix, a colon-tagged size or a local Ollama
      # server's cloud marker, with dots as dashes, so the same model under
      # two spellings keys one row.
      def normalize(model)
        name = ollama_canonical(model.to_s.strip.downcase)
        name = name.split("/").last.to_s
        name = name.sub(/-\d{8}\z/, "").sub(/-\d{4}-\d{2}-\d{2}\z/, "")
        name.tr(".", "-")
      end

      # The provider as the registry names it, from how a trace or a run
      # recorded it: downcased, cut at "::" ("OpenAI::Chat" → "openai"),
      # and the few other spellings mapped (PROVIDER_SLUGS). nil for none.
      #
      # @return [String, nil]
      def provider_slug(provider)
        slug = provider.to_s.strip.downcase.split("::").first.to_s
        return nil if slug.empty?

        PROVIDER_SLUGS.fetch(slug, slug)
      end

      # Whether +model+ is an Ollama model: run under Ollama (either
      # provider name), or spelled with a local server's cloud marker.
      def ollama?(model, provider = nil)
        OLLAMA_PROVIDERS.include?(provider_slug(provider)) || ollama_cloud_model?(model)
      end

      # Whether +model+ carries a local Ollama server's cloud marker.
      def ollama_cloud_model?(model)
        name = model.to_s.strip
        OLLAMA_CLOUD_MARKERS.any? { |marker| name.end_with?(marker) }
      end

      # The name Ollama Cloud lists a model under: "gpt-oss:120b-cloud" →
      # "gpt-oss:120b", "glm-4.6:cloud" → "glm-4.6"; any other name as given.
      def ollama_canonical(model)
        name = model.to_s.strip
        OLLAMA_CLOUD_MARKERS.each { |marker| return name.delete_suffix(marker) if name.end_with?(marker) }
        name
      end

      private

      # The registry's rate for the first spelling it knows: an Ollama
      # model under the cloud's listing by the name the cloud uses, then
      # the name as given under the provider it ran on, then bare, then
      # with a gateway or vendor prefix stripped (under the vendor's own
      # provider), each with its dots and dashes swapped and its date
      # suffix dropped.
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
        candidates = []

        if ollama?(name, provider)
          ollama_names(name).each do |candidate|
            candidates << [ candidate, OLLAMA_CLOUD_PROVIDER ]
            candidates << [ candidate, "ollama" ]
          end
        end

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

      # The names Ollama Cloud's listing may hold an Ollama model under: the
      # name the cloud uses, then without a `:latest` tag.
      def ollama_names(model)
        canonical = ollama_canonical(model)
        [ canonical, canonical.delete_suffix(":latest") ].uniq
      end

      # Ollama Cloud's own row for an Ollama model, else an exact row for
      # the normalised name, else the first pattern the name as given
      # matches, else the default.
      def static_rate(model, provider = nil)
        if ollama?(model, provider) && (row = ollama_names(model).filter_map { |name| OLLAMA_CLOUD_RATES[name] }.first)
          return { input: row[0], output: row[1], source: "catalog" }
        end

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
