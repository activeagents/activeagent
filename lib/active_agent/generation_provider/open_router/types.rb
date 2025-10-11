# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenRouter
      module Types
        class ResponseFormatType < ActiveModel::Type::Value
          def cast(value)
            case value
            when ResponseFormat
              value
            when Hash
              ResponseFormat.new(**value.symbolize_keys)
            when String
              ResponseFormat.new(type: value)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to ResponseFormat"
            end
          end

          def serialize(value)
            case value
            when ResponseFormat
              value.to_h
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

        class PredictionType < ActiveModel::Type::Value
          def cast(value)
            case value
            when Prediction
              value
            when Hash
              Prediction.new(**value.symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to Prediction"
            end
          end

          def serialize(value)
            case value
            when Prediction
              value.to_h
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

        class ProviderPreferencesType < ActiveModel::Type::Value
          def cast(value)
            case value
            when ProviderPreferences
              value
            when Hash
              ProviderPreferences.new(**value.symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to ProviderPreferences"
            end
          end

          def serialize(value)
            case value
            when ProviderPreferences
              value.to_h
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

        class MaxPriceType < ActiveModel::Type::Value
          def cast(value)
            case value
            when MaxPrice
              value
            when Hash
              MaxPrice.new(**value.symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to MaxPrice"
            end
          end

          def serialize(value)
            case value
            when MaxPrice
              value.to_h
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
