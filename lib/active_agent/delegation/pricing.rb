# frozen_string_literal: true

module ActiveAgent
  module Delegation
    # Token price registry used to turn usage into dollars for cost budgets.
    #
    # ActiveAgent deliberately ships no built-in price list: vendor pricing
    # changes far faster than a gem release, and a stale table silently
    # under-reports spend. Register the rates your app actually pays — once,
    # in an initializer — and every cost budget in the app uses them.
    #
    # Rates are expressed in **USD per one million tokens**, matching how
    # every major provider publishes them.
    #
    # @example Register rates for the models you use
    #   # config/initializers/active_agent.rb
    #   ActiveAgent::Delegation::Pricing.register("gpt-4o-mini", input: 0.15, output: 0.60)
    #   ActiveAgent::Delegation::Pricing.register(/\Aclaude-haiku/, input: 1.00, output: 5.00)
    #
    # @example Or state rates inline on a single budget
    #   delegate_to SummarizerAgent, budget: { max_cost: 0.05, rates: { input: 0.15, output: 0.60 } }
    module Pricing
      # A registered rate card.
      Rate = Struct.new(:pattern, :input, :output, keyword_init: true) do
        # @param model [String]
        # @return [Boolean]
        def matches?(model)
          case pattern
          when Regexp then pattern.match?(model)
          else model.to_s.start_with?(pattern.to_s)
          end
        end
      end

      class << self
        # @return [Array<Rate>] registered rates, most recently registered first
        def rates
          @rates ||= []
        end

        # Registers a rate card.
        #
        # String patterns match by prefix (so +"gpt-4o-mini"+ covers
        # +"gpt-4o-mini-2024-07-18"+); Regexp patterns match as written. Later
        # registrations win over earlier ones.
        #
        # @param pattern [String, Regexp] matched against the model name
        # @param input [Float] USD per 1M input tokens
        # @param output [Float] USD per 1M output tokens
        # @return [Rate]
        def register(pattern, input:, output:)
          Rate.new(pattern: pattern, input: input.to_f, output: output.to_f).tap do |rate|
            rates.unshift(rate)
          end
        end

        # Clears the registry. Mostly useful in tests.
        #
        # @return [void]
        def reset!
          @rates = []
        end

        # @param model [String, nil]
        # @return [Hash, nil] +{ input:, output: }+ in USD per 1M tokens
        def rates_for(model)
          return nil if model.blank?

          rate = rates.find { |candidate| candidate.matches?(model) }
          { input: rate.input, output: rate.output } if rate
        end

        # Computes the dollar cost of a single generation.
        #
        # @param usage [ActiveAgent::Providers::Common::Usage, nil]
        # @param model [String, nil] used to look up registered rates
        # @param rates [Hash, nil] inline +{ input:, output: }+ overriding the registry
        # @return [Float, nil] nil when no rates are known for the model
        def cost_for(usage:, model: nil, rates: nil)
          return nil if usage.nil?

          resolved = normalize(rates) || rates_for(model)
          return nil if resolved.nil?

          input  = (usage.input_tokens  || 0) * resolved[:input]
          output = (usage.output_tokens || 0) * resolved[:output]

          (input + output) / 1_000_000.0
        end

        private

        # @param rates [Hash, nil]
        # @return [Hash, nil]
        def normalize(rates)
          return nil if rates.blank?

          rates = rates.symbolize_keys
          return nil unless rates[:input] || rates[:output]

          { input: rates[:input].to_f, output: rates[:output].to_f }
        end
      end
    end
  end
end
