# frozen_string_literal: true

require_relative "messages/_types"
require_relative "provider_preferences/_types"

require_relative "message"
require_relative "prediction"
require_relative "provider_preferences"
require_relative "response_format"

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Type for MaxPrice
        class MaxPriceType < ActiveModel::Type::Value
          def cast(value)
            case value
            when MaxPrice
              value
            when Hash
              MaxPrice.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to MaxPrice"
            end
          end

          def serialize(value)
            case value
            when MaxPrice
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          def deserialize(value)
            cast(value)
          end
        end

        # Type for Prediction
        class PredictionType < ActiveModel::Type::Value
          def cast(value)
            case value
            when Prediction
              value
            when Hash
              Prediction.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to Prediction"
            end
          end

          def serialize(value)
            case value
            when Prediction
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          def deserialize(value)
            cast(value)
          end
        end

        # Type for ProviderPreferences
        class ProviderPreferencesType < ActiveModel::Type::Value
          def cast(value)
            case value
            when ProviderPreferences
              value
            when Hash
              ProviderPreferences.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to ProviderPreferences"
            end
          end

          def serialize(value)
            case value
            when ProviderPreferences
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          def deserialize(value)
            cast(value)
          end
        end

        # Type for ResponseFormat
        class ResponseFormatType < ActiveModel::Type::Value
          def cast(value)
            case value
            when ResponseFormat
              value
            when Hash
              ResponseFormat.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to ResponseFormat"
            end
          end

          def serialize(value)
            case value
            when ResponseFormat
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          def deserialize(value)
            cast(value)
          end
        end
      end
    end
  end
end
