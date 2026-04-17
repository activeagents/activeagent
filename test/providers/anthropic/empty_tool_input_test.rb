# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    class EmptyToolInputTest < ActiveSupport::TestCase
      setup do
        @provider = ActiveAgent::Providers::AnthropicProvider.new(
          service: "Anthropic",
          model: "claude-sonnet-4-5",
          messages: [ { role: "user", content: "Hello" } ],
          stream_broadcaster: ->(message, delta, event_type) { }
        )
      end

      test "handles empty string input for tools with no parameters" do
        @provider.send(:message_stack).push({
          role: "assistant",
          content: [
            { type: "tool_use", id: "tool_123", name: "no_param_tool", input: "" }
          ]
        })

        result = @provider.send(:process_prompt_finished_extract_function_calls)

        assert_equal 1, result.size
        assert_equal({}, result.first[:input])
      end

      test "handles empty json_buf gracefully" do
        @provider.send(:message_stack).push({
          role: "assistant",
          content: [
            { type: "tool_use", id: "tool_123", name: "no_param_tool", json_buf: "", input: nil }
          ]
        })

        result = @provider.send(:process_prompt_finished_extract_function_calls)

        assert_equal 1, result.size
        assert_nil result.first[:input]
      end
    end
  end
end
