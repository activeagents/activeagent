# frozen_string_literal: true

require_relative "content/_types"

require_relative "base"
require_relative "user_message"
require_relative "system_message"
require_relative "developer_message"
require_relative "assistant_message"
require_relative "tool_message"
require_relative "function_call_output"
require_relative "item_reference"
require_relative "reasoning"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Type for handling messages (array of messages)
            class MessagesType < ActiveModel::Type::Value
              def initialize
                super
                @message_type = MessageType.new
              end

              def cast(value)
                case value
                when String
                  value
                when Array
                  value.map { |item| @message_type.cast(item) }
                when Hash
                  # Single hash becomes array with one message
                  [ @message_type.cast(value) ]
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Input (expected String, Array, or Hash)"
                end
              end

              def serialize(value)
                case value
                when String
                  value
                when Array
                  value.map { |item| @message_type.serialize(item) }
                when Hash
                  @message_type.serialize(value)
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

            # Type for handling individual input messages
            class MessageType < ActiveModel::Type::Value
              def initialize
                super
                @content_type = Content::ContentType.new
              end

              def cast(value)
                case value
                when Base
                  value
                when Hash
                  role = value[:role]&.to_s || value["role"]&.to_s

                  # Handle content - can be string or array
                  if value[:content].is_a?(Array) || value["content"].is_a?(Array)
                    content = value[:content] || value["content"]
                    typed_content = content.map { |part| @content_type.cast(part) }
                    value = value.merge(content: typed_content)
                  end

                  case role
                  when "system"
                    SystemMessage.new(**value.symbolize_keys)
                  when "user"
                    UserMessage.new(**value.symbolize_keys)
                  when "assistant"
                    AssistantMessage.new(**value.symbolize_keys)
                  when "tool"
                    ToolMessage.new(**value.symbolize_keys)
                  else
                    # Return hash as-is if role is unknown
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
                when Base
                  hash = value.serialize
                  # Serialize content array if present
                  if hash[:content].is_a?(Array)
                    hash[:content] = hash[:content].map { |part| @content_type.serialize(part) }
                    # Compress single input_text to string
                    if hash[:content].one? && hash[:content].first.is_a?(Hash) && hash[:content].first[:type] == "input_text"
                      hash[:content] = hash[:content].first[:text]
                    end
                  end
                  hash
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
          end
        end
      end
    end
  end
end
