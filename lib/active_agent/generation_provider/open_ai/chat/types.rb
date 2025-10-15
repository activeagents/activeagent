# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        module Types
          class AudioType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Audio
                value
              when Hash
                Audio.new(**value.symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Audio"
              end
            end

            def serialize(value)
              case value
              when Audio
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

          class ResponseFormatType < ActiveModel::Type::Value
            def cast(value)
              case value
              when ResponseFormat
                value
              when Hash
                ResponseFormat.new(**value.symbolize_keys)
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

          class StreamOptionsType < ActiveModel::Type::Value
            def cast(value)
              case value
              when StreamOptions
                value
              when Hash
                StreamOptions.new(**value.symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to StreamOptions"
              end
            end

            def serialize(value)
              case value
              when StreamOptions
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

          class WebSearchOptionsType < ActiveModel::Type::Value
            def cast(value)
              case value
              when WebSearchOptions
                value
              when Hash
                WebSearchOptions.new(**value.symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to WebSearchOptions"
              end
            end

            def serialize(value)
              case value
              when WebSearchOptions
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
end
