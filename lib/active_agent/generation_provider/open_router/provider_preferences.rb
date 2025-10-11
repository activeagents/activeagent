# frozen_string_literal: true

require_relative "max_price"
require_relative "types"

module ActiveAgent
  module GenerationProvider
    module OpenRouter
      # Provider preferences for routing requests to specific providers
      # See: https://openrouter.ai/docs/provider-routing
      class ProviderPreferences < Common::Options

        # Whether to allow backup providers to serve requests
        # - true: (default) when primary provider is unavailable, use next best provider
        # - false: use only primary/custom provider, return upstream error if unavailable
        attribute :allow_fallbacks, :boolean

        # Whether to filter providers to only those that support provided parameters
        # If false, providers receive only parameters they support and ignore the rest
        attribute :require_parameters, :boolean

        # Data collection setting
        # - allow: (default) allow providers which store user data and may train on it
        # - deny: use only providers which do not collect user data
        attribute :data_collection, :string

        # Zero Data Retention - stricter privacy mode
        attribute :zdr, :boolean

        # Ordered list of provider slugs to try in order
        attribute :order, default: -> { [] }

        # List of provider slugs to allow (merged with account-wide settings)
        attribute :only, default: -> { [] }

        # List of provider slugs to ignore (merged with account-wide settings)
        attribute :ignore, default: -> { [] }

        # List of quantization levels to filter providers by
        # Options: int4, int8, fp4, fp6, fp8, fp16, bf16, fp32, unknown
        attribute :quantizations, default: -> { [] }

        # Sorting strategy to use if "order" is not specified
        # Options: price, throughput, latency
        # When set, no load balancing is performed
        attribute :sort, :string

        # Maximum price constraints (USD per million tokens)
        attribute :max_price, Types::MaxPriceType.new

        # Validations matching the schema
        validates :data_collection, inclusion: { in: %w[deny allow] }, allow_nil: true
        validates :sort, inclusion: { in: %w[price throughput latency] }, allow_nil: true
        validates :quantizations, inclusion: {
          in: [%w[int4 int8 fp4 fp6 fp8 fp16 bf16 fp32 unknown].freeze],
          message: "must contain valid quantization levels"
        }, allow_nil: true, if: -> { quantizations.is_a?(Array) && quantizations.any? }

        # Backwards Compatibility
        alias_attribute :enable_fallbacks, :allow_fallbacks
      end
    end
  end
end
