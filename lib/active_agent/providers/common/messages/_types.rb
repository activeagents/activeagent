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
                when "system", "developer"
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
                # Check if it's a gem model object that can be converted to hash
                # Use JSON round-trip to ensure proper nested serialization
                elsif value.respond_to?(:to_json)
                  hash = JSON.parse(value.to_json, symbolize_names: true)
                  cast_message(hash)
                elsif value.respond_to?(:to_h)
                  cast_message(value.to_h)
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
                messages = value.map { |v| message_type.cast(v) }.compact
                # Split messages with array content into separate messages
                messages.flat_map { |msg| split_content_blocks(msg) }
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

            # Splits an assistant message with array content into separate messages
            # for each content block.
            #
            # @param message [Common::Messages::Base]
            # @return [Array<Common::Messages::Base>]
            def split_content_blocks(message)
              # Only split assistant messages with array content
              return [ message ] unless message.is_a?(Common::Messages::Assistant) && message.content.is_a?(Array)

              message.content.map do |block|
                case block[:type]&.to_s
                when "text"
                  # Create a message for text blocks
                  Common::Messages::Assistant.new(role: "assistant", content: block[:text], name: message.name)
                when "tool_use"
                  # Create a message with tool use info as string representation
                  input = block[:input]
                  input_str = input.nil? || input.empty? ? "{}" : JSON.pretty_generate(input)
                  tool_info = "[Tool Use: #{block[:name]}]\nID: #{block[:id]}\nInput: #{input_str}"
                  Common::Messages::Assistant.new(role: "assistant", content: tool_info, name: message.name)
                when "mcp_tool_use"
                  # Create a message with MCP tool use info
                  input = block[:input]
                  input_str = input.nil? || input.empty? ? "{}" : JSON.pretty_generate(input)
                  tool_info = "[MCP Tool Use: #{block[:name]}]\nID: #{block[:id]}\nServer: #{block[:server_name]}\nInput: #{input_str}"
                  Common::Messages::Assistant.new(role: "assistant", content: tool_info, name: message.name)
                when "mcp_tool_result"
                  # Create a message with MCP tool result
                  result_info = "[MCP Tool Result]\n#{block[:content]}"
                  Common::Messages::Assistant.new(role: "assistant", content: result_info, name: message.name)
                else
                  # For unknown block types, try to extract text
                  content = block[:text] || block.to_s
                  Common::Messages::Assistant.new(role: "assistant", content:, name: message.name)
                end
              end.compact
            end
          end
        end
      end
    end
  end
end
