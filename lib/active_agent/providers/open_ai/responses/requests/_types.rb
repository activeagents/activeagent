# frozen_string_literal: true

require_relative "inputs/_types"
require_relative "tools/_types"

require_relative "conversation"
require_relative "prompt_reference"
require_relative "reasoning"
require_relative "stream_options"
require_relative "text"
require_relative "tool_choice"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          class ConversationType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Conversation
                value
              when Hash
                Conversation.new(**value.symbolize_keys)
              when String
                value # Can be a conversation ID string
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Conversation"
              end
            end

            def serialize(value)
              case value
              when Conversation
                value.serialize
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

          class PromptReferenceType < ActiveModel::Type::Value
            def cast(value)
              case value
              when PromptReference
                value
              when Hash
                PromptReference.new(**value.symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to PromptReference"
              end
            end

            def serialize(value)
              case value
              when PromptReference
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

          class ReasoningType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Reasoning
                value
              when Hash
                Reasoning.new(**value.symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Reasoning"
              end
            end

            def serialize(value)
              case value
              when Reasoning
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

          class TextType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Text
                value
              when Hash
                if value.key?(:json_schema)
                  Text.new(**value.symbolize_keys.except(:type)) # Prevent Losing the Schema on Format setting
                else
                  Text.new(**value.symbolize_keys)
                end
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Text"
              end
            end

            def serialize(value)
              case value
              when Text
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
                if hash[:mode].present? && hash[:type].blank? && hash[:function].blank? && hash[:custom].blank?
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
        end
      end
    end
  end
end
