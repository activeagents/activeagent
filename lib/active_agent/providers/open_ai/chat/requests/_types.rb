# frozen_string_literal: true

require_relative "messages/_types"
require_relative "tools/_types"

require_relative "audio"
require_relative "prediction"
require_relative "response_format"
require_relative "stream_options"
require_relative "tool_choice"
require_relative "web_search_options"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          # Type for Audio
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

          # Type for StreamOptions
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

          # Type for ToolChoice
          class ToolChoiceType < ActiveModel::Type::Value
            def cast(value)
              case value
              when ToolChoice
                value
              when Hash
                ToolChoice.new(**value.symbolize_keys)
              when String
                ToolChoice.new(mode: value)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to ToolChoice"
              end
            end

            def serialize(value)
              case value
              when ToolChoice
                hash = value.serialize
                # If it's just a mode string, return the string
                if hash[:mode].present? && hash[:type].blank? && hash[:function].blank? && hash[:custom].blank? && hash[:allowed_tools].blank?
                  hash[:mode]
                else
                  hash
                end
              when Hash
                value
              when String
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

          # Type for WebSearchOptions
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
end
