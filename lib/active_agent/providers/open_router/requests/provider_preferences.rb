# frozen_string_literal: true

require_relative "provider_preferences/_types"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Provider preferences for routing requests to specific providers
        #
        # Controls how OpenRouter selects and routes requests to underlying model
        # providers. Enables filtering by parameters, cost constraints, privacy
        # settings, and provider-specific preferences.
        #
        # @example Basic provider routing
        #   prefs = ProviderPreferences.new(
        #     require_parameters: true,
        #     allow_fallbacks: false
        #   )
        #
        # @example Privacy-focused routing
        #   prefs = ProviderPreferences.new(
        #     data_collection: 'deny',
        #     zdr: true
        #   )
        #
        # @example Cost-optimized routing
        #   prefs = ProviderPreferences.new(
        #     sort: 'price',
        #     max_price: { prompt: 0.01, completion: 0.03 }
        #   )
        #
        # @example Provider ordering
        #   prefs = ProviderPreferences.new(
        #     order: ['OpenAI', 'Anthropic'],
        #     ignore: ['Together']
        #   )
        #
        # @see https://openrouter.ai/docs/provider-routing OpenRouter Provider Routing
        # @see MaxPrice
        class ProviderPreferences < Common::BaseModel
          # @!attribute allow_fallbacks
          #   @return [Boolean, nil] whether to allow backup providers when primary is unavailable
          #     - true: (default) use next best provider when primary unavailable
          #     - false: only use primary/custom provider, return error if unavailable
          attribute :allow_fallbacks, :boolean

          # @!attribute require_parameters
          #   @return [Boolean, nil] whether to filter to providers supporting all parameters
          #     - true: only use providers that support all provided parameters
          #     - false: providers receive only the parameters they support
          attribute :require_parameters, :boolean

          # @!attribute data_collection
          #   @return [String, nil] data collection preference
          #     - 'allow': (default) allow providers which store/train on user data
          #     - 'deny': only use providers that don't collect user data
          attribute :data_collection, :string

          # @!attribute zdr
          #   @return [Boolean, nil] zero data retention mode (stricter privacy)
          attribute :zdr, :boolean

          # @!attribute order
          #   @return [Array<String>] ordered list of provider slugs to try in sequence
          attribute :order, default: -> { [] }

          # @!attribute only
          #   @return [Array<String>] allowlist of provider slugs (merged with account settings)
          attribute :only, default: -> { [] }

          # @!attribute ignore
          #   @return [Array<String>] blocklist of provider slugs (merged with account settings)
          attribute :ignore, default: -> { [] }

          # @!attribute quantizations
          #   @return [Array<String>] quantization levels to filter providers by
          #     Options: int4, int8, fp4, fp6, fp8, fp16, bf16, fp32, unknown
          attribute :quantizations, default: -> { [] }

          # @!attribute sort
          #   @return [String, nil] sorting strategy when order not specified
          #     Options: price, throughput, latency
          #     Note: disables load balancing when set
          attribute :sort, :string

          # @!attribute max_price
          #   @return [MaxPrice, nil] maximum price constraints per token/operation
          attribute :max_price, MaxPriceType.new

          # Validations matching the schema
          validates :data_collection, inclusion: { in: %w[deny allow] }, allow_nil: true
          validates :sort, inclusion: { in: %w[price throughput latency] }, allow_nil: true
          validates :quantizations, inclusion: {
            in: [ %w[int4 int8 fp4 fp6 fp8 fp16 bf16 fp32 unknown].freeze ],
            message: "must contain valid quantization levels"
          }, allow_nil: true, if: -> { quantizations.is_a?(Array) && quantizations.any? }

          # Backwards Compatibility
          alias_attribute :enable_fallbacks, :allow_fallbacks
        end
      end
    end
  end
end
