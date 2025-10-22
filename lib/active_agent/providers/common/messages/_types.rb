# frozen_string_literal: true

require_relative "user"
require_relative "assistant"
require_relative "tool"

module ActiveAgent
  module Providers
    module Common
      module Messages
        module Types
          # Type for a single Message
          class MessageType < ActiveModel::Type::Value
            def cast(value)
              cast_message(value)
            end

            def serialize(value)
              serialize_message(value)
            end

            def deserialize(value)
              cast(value)
            end

            private

            def cast_message(value)
              case value
              when Common::Messages::Base
                value
              when String
                # Convert bare strings to user messages
                Common::Messages::User.new(content: value)
              when Hash
                hash = value.deep_symbolize_keys
                role = hash[:role]&.to_s

                case role
                when "system"
                  nil # System messages are dropped in common format, replaced by Instructions
                when "user", nil
                  # Handle both standard format and format with `text` key
                  if hash[:text] && !hash[:content]
                    Common::Messages::User.new(content: hash[:text])
                  else
                    # Filter to only known attributes for User
                    filtered_hash = hash.slice(:role, :content, :name)
                    Common::Messages::User.new(**filtered_hash.merge(role: "user"))
                  end
                when "assistant"
                  # Filter to only known attributes for Assistant
                  filtered_hash = hash.slice(:role, :content, :name)
                  Common::Messages::Assistant.new(**filtered_hash)
                when "tool"
                  # Filter to only known attributes for Tool
                  filtered_hash = hash.slice(:role, :content, :tool_call_id)
                  Common::Messages::Tool.new(**filtered_hash)
                else
                  raise ArgumentError, "Unknown message role: #{role}"
                end
              else
                # Check if the value responds to to_common (provider-specific message)
                if value.respond_to?(:to_common)
                  cast_message(value.to_common)
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Message"
                end
              end
            end

            def serialize_message(value)
              case value
              when nil
                nil
              when Common::Messages::Base
                value.to_h
              when Hash
                value
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end
          end

          # Type for Messages array
          class MessagesType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Array
                value.map { |v| message_type.cast(v) }.compact
              when nil
                []
              else
                raise ArgumentError, "Cannot cast #{value.class} to Messages array"
              end
            end

            def serialize(value)
              case value
              when Array
                value.map { |v| message_type.serialize(v) }.compact
              when nil
                []
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end

            private

            def message_type
              @message_type ||= MessageType.new
            end
          end
        end
      end
    end
  end
end
