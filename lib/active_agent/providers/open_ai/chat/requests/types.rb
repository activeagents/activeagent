# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
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
                value.to_h
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

          class MessageType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Messages::Base
                value
              when Hash
                role = value[:role]&.to_s || value["role"]&.to_s

                case role
                when "developer"
                  Messages::Developer.new(**value.symbolize_keys)
                when "system"
                  Messages::System.new(**value.symbolize_keys)
                when "user"
                  Messages::User.new(**value.symbolize_keys)
                when "assistant"
                  Messages::Assistant.new(**value.symbolize_keys)
                when "tool"
                  Messages::Tool.new(**value.symbolize_keys)
                when "function"
                  Messages::Function.new(**value.symbolize_keys)
                else
                  # If no role specified or unknown, return as-is
                  value
                end
              when nil
                nil
              else
                value
              end
            end

            def serialize(value)
              case value
              when Messages::Base
                value.to_h
              when Hash
                value
              when nil
                nil
              else
                value
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          class MessagesType < ActiveModel::Type::Value
            def initialize
              super
              @message_type = MessageType.new
            end

            def cast(value)
              return nil if value.nil?
              return [] if value == []

              array = Array(value)
              array.map { |msg| @message_type.cast(msg) }
            end

            def serialize(value)
              return nil if value.nil?
              return [] if value == []

              array = Array(value)
              array.map { |msg| @message_type.serialize(msg) }
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
end
