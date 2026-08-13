# frozen_string_literal: true

module ActionAgent
  # Estimates LLM spend from token counts. The activeagent gem's telemetry
  # records tokens only; the platform layers pricing on top for the cost
  # figures shown in Traces and Metrics.
  #
  # Rates come from RubyLLM's model registry (USD per million tokens,
  # maintained upstream per model) when the model is known there; the static
  # pattern table below is the fallback for aliases/self-hosted models, and
  # a conservative blended rate covers everything else so totals stay
  # meaningful. Costs are always presented as estimates.
  class ModelPricing
    PRICES = [
      # [pattern, input $/1M, output $/1M]
      [ /gpt-4o-mini/i, 0.15, 0.60 ],
      [ /gpt-4o/i, 2.50, 10.00 ],
      [ /gpt-4\.1-nano/i, 0.10, 0.40 ],
      [ /gpt-4\.1-mini/i, 0.40, 1.60 ],
      [ /gpt-4\.1/i, 2.00, 8.00 ],
      [ /o3-mini|o4-mini/i, 1.10, 4.40 ],
      [ /claude.*(fable|mythos)/i, 10.00, 50.00 ],
      [ /claude.*haiku-?4/i, 1.00, 5.00 ],
      [ /claude.*(haiku)/i, 0.80, 4.00 ],
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

    # @return [Float, nil] estimated USD cost, nil when there is nothing to price
    def self.estimate(model:, input_tokens:, output_tokens:)
      input = input_tokens.to_i
      output = output_tokens.to_i
      return nil if input.zero? && output.zero?

      input_rate, output_rate = rate_for(model)
      ((input * input_rate) + (output * output_rate)) / 1_000_000.0
    end

    def self.rate_for(model)
      return DEFAULT_RATE if model.blank?

      registry_rate(model) || static_rate(model)
    end

    # Exact per-model rates from RubyLLM's registry. Lookups are memoized —
    # the registry scan is not free and trace serialization calls this per
    # row.
    def self.registry_rate(model)
      @registry_rates ||= {}
      return @registry_rates[model] if @registry_rates.key?(model)

      @registry_rates[model] = begin
        info = RubyLLM.models.find(model.to_s)
        tokens = info&.pricing&.text_tokens
        if tokens&.input && tokens&.output
          [ tokens.input, tokens.output ]
        end
      rescue StandardError
        nil
      end
    end

    def self.static_rate(model)
      PRICES.each do |pattern, input_rate, output_rate|
        return [ input_rate, output_rate ] if model.to_s.match?(pattern)
      end
      DEFAULT_RATE
    end
  end
end
