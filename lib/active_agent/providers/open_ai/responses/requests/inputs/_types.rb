# frozen_string_literal: true

require_relative "content/_types"

require_relative "base"
require_relative "tool_call_base"
require_relative "input_message"
require_relative "output_message"
require_relative "user_message"
require_relative "system_message"
require_relative "developer_message"
require_relative "assistant_message"
require_relative "tool_message"
require_relative "function_call_output"
require_relative "item_reference"
require_relative "reasoning"

# Tool call types
require_relative "file_search_tool_call"
require_relative "computer_tool_call"
require_relative "computer_tool_call_output"
require_relative "web_search_tool_call"
require_relative "function_tool_call"
require_relative "image_gen_tool_call"
require_relative "code_interpreter_tool_call"
require_relative "local_shell_tool_call"
require_relative "local_shell_tool_call_output"
require_relative "custom_tool_call"
require_relative "custom_tool_call_output"

# MCP types
require_relative "mcp_list_tools"
require_relative "mcp_approval_request"
require_relative "mcp_approval_response"
require_relative "mcp_tool_call"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Type for handling items (array of items - full Item types)
            class ItemsType < ActiveModel::Type::Value
              def initialize
                super
                @item_type = ItemType.new
              end

              def cast(value)
                case value
                when String
                  # Plain text string becomes array with single user message
                  [ UserMessage.new(text: value) ]
                when Array
                  value.map { |item| @item_type.cast(item) }
                when Hash
                  # Single hash becomes array with one item
                  [ @item_type.cast(value) ]
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Items (expected String, Array, Hash, or nil)"
                end
              end

              def serialize(value)
                case value
                when String
                  value
                when Array
                  value.map { |v| @item_type.serialize(v) }
                when Hash
                  @item_type.serialize(value)
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

            # Type for handling individual items (messages, tool calls, reasoning, etc.)
            class ItemType < ActiveModel::Type::Value
              def initialize
                super
                @content_type = Content::ContentType.new
              end

              def cast(value)
                case value
                when ::OpenAI::Internal::Type::BaseModel
                  cast(value.to_h)
                when Base
                  value
                when String
                  # Plain text string becomes user message
                  UserMessage.new(text: value)
                when Hash
                  hash = value.deep_symbolize_keys
                  type = hash[:type]&.to_sym

                  case type
                  # Message types
                  when :message, nil
                    cast_message(hash)
                  # Tool call types
                  when :file_search_call
                    FileSearchToolCall.new(**hash)
                  when :computer_call
                    ComputerToolCall.new(**hash)
                  when :computer_call_output
                    ComputerToolCallOutput.new(**hash)
                  when :web_search_call
                    WebSearchToolCall.new(**hash)
                  when :function_call
                    FunctionToolCall.new(**hash)
                  when :function_call_output
                    FunctionCallOutput.new(**hash)
                  when :image_generation_call
                    ImageGenToolCall.new(**hash)
                  when :code_interpreter_call
                    CodeInterpreterToolCall.new(**hash)
                  when :local_shell_call
                    LocalShellToolCall.new(**hash)
                  when :local_shell_call_output
                    LocalShellToolCallOutput.new(**hash)
                  when :custom_tool_call
                    CustomToolCall.new(**hash)
                  when :custom_tool_call_output
                    CustomToolCallOutput.new(**hash)
                  # MCP types
                  when :mcp_list_tools
                    MCPListTools.new(**hash)
                  when :mcp_approval_request
                    MCPApprovalRequest.new(**hash)
                  when :mcp_approval_response
                    MCPApprovalResponse.new(**hash)
                  when :mcp_call
                    MCPToolCall.new(**hash)
                  # Other types
                  when :reasoning
                    Reasoning.new(**hash)
                  when :item_reference
                    ItemReference.new(**hash)
                  else
                    raise ArgumentError, "Unknown item type: #{type.inspect}"
                  end
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Item (expected Base, Hash, String, or nil)"
                end
              end

              def serialize(value)
                case value
                when Base
                  hash = value.serialize

                  if hash[:content] in [ { type: "input_text", text: String } ]
                    hash[:content] = hash[:content].first[:text]
                  end

                  hash
                when Hash
                  value
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot serialize #{value.class} as Item"
                end
              end

              def deserialize(value)
                cast(value)
              end

              private

              def cast_message(hash)
                role = hash[:role]&.to_sym

                case role
                when :system
                  SystemMessage.new(**hash)
                when :developer
                  DeveloperMessage.new(**hash)
                when :user, nil
                  UserMessage.new(**hash)
                when :assistant
                  AssistantMessage.new(**hash)
                when :tool
                  ToolMessage.new(**hash)
                else
                  raise ArgumentError, "Unknown message role: #{role.inspect}"
                end
              end
            end

            # Type for handling messages (array of messages) - kept for backwards compatibility
            class MessagesType < ActiveModel::Type::Value
              def initialize
                super
                @item_type = ItemType.new
              end

              def cast(value)
                case value
                when String
                  value
                when Array
                  value.map { |item| @item_type.cast(item) }
                when Hash
                  # Single hash becomes array with one message
                  [ @item_type.cast(value) ]
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
                  grouped = []

                  value.each do |message|
                    if grouped.empty?
                      grouped << message.deep_dup
                    elsif grouped.last.role == message.role && grouped.last.type == message.type
                      grouped.last.content += message.content.deep_dup
                    else
                      grouped << message.deep_dup
                    end
                  end

                  grouped.map { |v| @item_type.serialize(v) }
                when Hash
                  @item_type.serialize(value)
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
