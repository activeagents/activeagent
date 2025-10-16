# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Responses
        module Requests
          module Types
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

            class TextType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Text
                  value
                when Hash
                  Text.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Text"
                end
              end

              def serialize(value)
                case value
                when Text
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
end
