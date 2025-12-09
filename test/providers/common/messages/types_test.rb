# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/common/messages/_types"

module ActiveAgent
  module Providers
    module Common
      module Messages
        class TypesTest < ActiveSupport::TestCase
          test "MessageType casts strings and hashes to appropriate message types" do
            message_type = create_message_type

            # String → User message
            user_result = message_type.cast("Hello")
            assert_instance_of ActiveAgent::Providers::Common::Messages::User, user_result
            assert_equal "Hello", user_result.content

            # Hash with user role → User message
            user_hash = message_type.cast({ role: "user", content: "Hi" })
            assert_instance_of ActiveAgent::Providers::Common::Messages::User, user_hash

            # Hash with assistant role → Assistant message
            assistant_result = message_type.cast({ role: "assistant", content: "Hello" })
            assert_instance_of ActiveAgent::Providers::Common::Messages::Assistant, assistant_result
          end

          test "MessageType drops system messages" do
            message_type = create_message_type
            result = message_type.cast({ role: "system", content: "System prompt" })
            assert_nil result
          end

          test "MessageType drops developer messages" do
            message_type = create_message_type
            result = message_type.cast({ role: "developer", content: "Developer prompt" })
            assert_nil result
          end

          test "MessagesType casts array of Hash messages to Message objects" do
            messages_type = create_messages_type
            messages = [
              { role: "user", content: "Hi" },
              { role: "assistant", content: "Hello" }
            ]
            result = messages_type.cast(messages)

            assert_equal 2, result.length
            assert_instance_of ActiveAgent::Providers::Common::Messages::User, result[0]
            assert_instance_of ActiveAgent::Providers::Common::Messages::Assistant, result[1]
          end

          test "MessagesType casts nil to empty array" do
            messages_type = create_messages_type
            result = messages_type.cast(nil)

            assert_equal [], result
          end

          test "MessagesType splits assistant message with array content into separate messages" do
            messages_type = create_messages_type
            messages = [
              {
                role: "assistant",
                content: [
                  { type: "text", text: "Hello" },
                  { type: "text", text: "World" }
                ]
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 2, result.length
            assert_all_instances_of(result, ActiveAgent::Providers::Common::Messages::Assistant)
            assert_equal "Hello", result[0].content
            assert_equal "World", result[1].content
          end

          test "MessagesType splits tool_use blocks into separate messages" do
            messages_type = create_messages_type
            messages = [
              {
                role: "assistant",
                content: [
                  { type: "text", text: "I'll help with that" },
                  {
                    type: "tool_use",
                    id: "tool_123",
                    name: "search",
                    input: { query: "test" }
                  }
                ]
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 2, result.length
            assert_all_instances_of(result, ActiveAgent::Providers::Common::Messages::Assistant)

            # First message is text
            assert_equal "I'll help with that", result[0].content

            # Second message contains tool info
            assert_includes result[1].content, "[Tool Use: search]"
            assert_includes result[1].content, "ID: tool_123"
            assert_includes result[1].content, "Input:"
          end

          test "MessagesType splits mcp_tool_use blocks into separate messages" do
            messages_type = create_messages_type
            messages = [
              {
                role: "assistant",
                content: [
                  { type: "text", text: "Using MCP" },
                  {
                    type: "mcp_tool_use",
                    id: "mcp_123",
                    name: "get_file",
                    server_name: "file_server",
                    input: { path: "/home/user/file.txt" }
                  }
                ]
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 2, result.length
            assert_all_instances_of(result, ActiveAgent::Providers::Common::Messages::Assistant)

            # MCP tool message
            mcp_message = result[1].content
            assert_includes mcp_message, "[MCP Tool Use: get_file]"
            assert_includes mcp_message, "ID: mcp_123"
            assert_includes mcp_message, "Server: file_server"
            assert_includes mcp_message, "Input:"
          end

          test "MessagesType splits mcp_tool_result blocks into separate messages" do
            messages_type = create_messages_type
            messages = [
              {
                role: "assistant",
                content: [
                  {
                    type: "mcp_tool_result",
                    id: "result_123",
                    name: "get_file",
                    content: "File contents here"
                  }
                ]
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 1, result.length
            result_message = result[0].content
            assert_includes result_message, "[MCP Tool Result]"
            assert_includes result_message, "File contents here"
          end

          test "MessagesType handles mixed content types in single message" do
            messages_type = create_messages_type
            messages = [
              {
                role: "assistant",
                content: [
                  { type: "text", text: "Text 1" },
                  {
                    type: "tool_use",
                    id: "tool_1",
                    name: "search",
                    input: { q: "test" }
                  },
                  { type: "text", text: "Text 2" }
                ]
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 3, result.length
            assert_all_instances_of(result, ActiveAgent::Providers::Common::Messages::Assistant)
            assert_equal "Text 1", result[0].content
            assert_includes result[1].content, "[Tool Use: search]"
            assert_equal "Text 2", result[2].content
          end

          test "MessagesType handles empty and nil inputs in tool blocks" do
            messages_type = create_messages_type

            # Empty input in tool_use block
            empty_input_result = messages_type.cast([
              {
                role: "assistant",
                content: [
                  {
                    type: "tool_use",
                    id: "tool_1",
                    name: "get_time",
                    input: {}
                  }
                ]
              }
            ])
            assert_equal 1, empty_input_result.length
            assert_includes empty_input_result[0].content, "Input: {}"

            # Nil input in mcp_tool_use block
            nil_input_result = messages_type.cast([
              {
                role: "assistant",
                content: [
                  {
                    type: "mcp_tool_use",
                    id: "mcp_1",
                    name: "ping",
                    server_name: "server",
                    input: nil
                  }
                ]
              }
            ])
            assert_equal 1, nil_input_result.length
            assert_includes nil_input_result[0].content, "Input: {}"
          end

          test "MessagesType preserves message name through split" do
            messages_type = create_messages_type
            messages = [
              {
                role: "assistant",
                name: "gpt-4",
                content: [
                  { type: "text", text: "Text 1" },
                  { type: "text", text: "Text 2" }
                ]
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 2, result.length
            result.each { |msg| assert_equal "gpt-4", msg.name }
          end

          test "MessagesType does not split non-assistant messages with array content" do
            messages_type = create_messages_type
            messages = [
              {
                role: "user",
                content: [ { type: "text", text: "User message" } ]
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 1, result.length
            assert_instance_of ActiveAgent::Providers::Common::Messages::User, result[0]
          end

          test "MessagesType does not split assistant messages with string content" do
            messages_type = create_messages_type
            messages = [
              {
                role: "assistant",
                content: "Simple string content"
              }
            ]
            result = messages_type.cast(messages)

            assert_equal 1, result.length
            assert_instance_of ActiveAgent::Providers::Common::Messages::Assistant, result[0]
            assert_equal "Simple string content", result[0].content
          end

          test "MessagesType compacts nil messages from system roles" do
            messages_type = create_messages_type
            messages = [
              { role: "system", content: "System prompt" },
              { role: "user", content: "User message" },
              { role: "system", content: "Another system prompt" },
              { role: "assistant", content: "Assistant response" }
            ]
            result = messages_type.cast(messages)

            assert_equal 2, result.length
            assert_instance_of ActiveAgent::Providers::Common::Messages::User, result[0]
            assert_instance_of ActiveAgent::Providers::Common::Messages::Assistant, result[1]
          end

          test "Assistant message parsed_json handles array content" do
            content_array = [
              { type: "text", text: '{"name": "John", "age": 30}' },
              { type: "text", text: "Some other text" }
            ]
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: content_array)

            result = assistant_message.parsed_json

            assert_not_nil result
            assert_equal "John", result[:name]
            assert_equal 30, result[:age]
          end

          test "Assistant message text method handles string and array content" do
            # String content
            string_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: "Hello World")
            assert_equal "Hello World", string_message.text

            # Array content
            array_message = ActiveAgent::Providers::Common::Messages::Assistant.new(
              content: [
                { type: "text", text: "Hello" },
                { type: "text", text: "World" }
              ]
            )
            assert_equal "Hello\nWorld", array_message.text
          end

          private

          def create_message_type
            # Access MessageType through the Types module
            ActiveAgent::Providers::Common::Messages::Types::MessageType.new
          end

          def create_messages_type
            # Access MessagesType through the Types module
            ActiveAgent::Providers::Common::Messages::Types::MessagesType.new
          end

          def assert_all_instances_of(array, klass)
            array.each { |item| assert_instance_of klass, item }
          end
        end
      end
    end
  end
end
