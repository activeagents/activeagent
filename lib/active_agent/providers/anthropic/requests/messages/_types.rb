# frozen_string_literal: true

# Load required dependencies
require_relative "base"
require_relative "user"
require_relative "assistant"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Messages
          # Type for Messages array
          class MessagesType < ActiveModel::Type::Value
            def initialize
              super
              @message_type = MessageType.new
            end

            def cast(value)
              case value
              when Array
                value.map { |v| @message_type.cast(v) }
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Messages array"
              end
            end

            def serialize(value)
              case value
              when Array
                grouped = []

                value.each do |message|
                  if grouped.empty? || grouped.last.role != message.role
                    grouped << message.deep_dup
                  else
                    grouped.last.content += message.content.deep_dup
                  end
                end

                grouped.map { |v| @message_type.serialize(v) }
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

          # Type for individual Message
          class MessageType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Base
                value
              when String
                User.new(content: value)
              when Hash
                # Symbolize keys once for consistent lookups
                hash = value.symbolize_keys
                role = hash[:role]&.to_s

                case role
                when "user", nil
                  User.new(**hash)
                when "assistant"
                  Assistant.new(**hash)
                else
                  raise ArgumentError, "Unknown message role: #{role}"
                end
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Message"
              end
            end

            def serialize(value)
              case value
              when Base
                hash = value.serialize
                # Compress single text content to string
                if hash[:content].is_a?(Array) && hash[:content].one? && hash[:content].first.is_a?(Hash) && hash[:content].first[:type] == "text"
                  hash[:content] = hash[:content].first[:text]
                end
                hash
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

          # Type for System content - converts strings to arrays of text blocks
          class SystemType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Array
                # Already an array - validate and return
                value.map { |block| cast_system_block(block) }
              when String
                # Convert string to array of text blocks
                [
                  {
                    type: "text",
                    text: value
                  }
                ]
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to System content"
              end
            end

            def serialize(value)
              case value
              when Array
                serialized = value.map { |block| serialize_system_block(block) }
                # Compress single text block to string
                if serialized.one? && serialized.first.is_a?(Hash) && serialized.first[:type] == "text"
                  serialized.first[:text]
                else
                  serialized
                end
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end

            private

            def cast_system_block(value)
              case value
              when Content::Base
                value
              when String
                Content::Text.new(text: value)
              when Hash
                # Symbolize keys once for consistent lookups
                hash = value.symbolize_keys
                type = hash[:type]&.to_s

                case type
                when "text"
                  Content::Text.new(**hash)
                else
                  raise ArgumentError, "Unknown system block type: #{type}"
                end
              else
                raise ArgumentError, "Cannot cast #{value.class} to system block"
              end
            end

            def serialize_system_block(value)
              case value
              when Content::Base
                value.serialize
              when Hash
                value
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end
          end
        end
      end
    end
  end
end
