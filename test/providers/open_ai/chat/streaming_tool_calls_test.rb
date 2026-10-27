# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenAI Chat streaming tool call tests"
  return
end

require_relative "../../../../lib/active_agent/providers/open_ai/chat_provider"

module Providers
  module OpenAI
    module Chat
      # OpenAI-compatible servers (Gemini's compatibility endpoint, some Ollama
      # and OpenRouter backends) stream tool calls without the `index` field the
      # OpenAI API sends. Their deltas must still end up as the right calls.
      class StreamingToolCallsTest < ActiveSupport::TestCase
        setup do
          @provider = ActiveAgent::Providers::OpenAI::ChatProvider.new(
            service: "OpenAI",
            api_key: "test-key",
            model: "gpt-5.6-terra",
            messages: [ { role: "user", content: "Hello" } ],
            stream_broadcaster: ->(message, delta, event_type) { }
          )
        end

        def merge(*deltas)
          message = { index: 0, role: "assistant" }
          deltas.each { |delta| @provider.send(:message_merge_delta, message, delta) }
          message
        end

        test "argument fragments without an index continue the call they follow" do
          message = merge(
            { tool_calls: [ { id: "call_1", type: "function", function: { name: "get_weather", arguments: "" } } ] },
            { tool_calls: [ { function: { arguments: "{\"city\":" } } ] },
            { tool_calls: [ { function: { arguments: "\"Boston\"}" } } ] }
          )

          assert_equal 1, message[:tool_calls].size
          assert_equal "get_weather", message[:tool_calls][0][:function][:name]
          assert_equal "{\"city\":\"Boston\"}", message[:tool_calls][0][:function][:arguments]
        end

        test "calls without an index are told apart by id" do
          message = merge(
            { tool_calls: [ { id: "call_1", type: "function", function: { name: "a", arguments: "{" } } ] },
            { tool_calls: [ { id: "call_2", type: "function", function: { name: "b", arguments: "{" } } ] },
            { tool_calls: [ { id: "call_1", function: { arguments: "}" } } ] }
          )

          assert_equal %w[a b], message[:tool_calls].map { _1[:function][:name] }
          assert_equal %w[{} {], message[:tool_calls].map { _1[:function][:arguments] }
        end

        test "an id, type and name repeated on every fragment are not concatenated" do
          call = ->(arguments) { { id: "call_1", type: "function", function: { name: "get_weather", arguments: } } }
          message = merge(
            { tool_calls: [ call.("") ] },
            { tool_calls: [ call.("{\"city\":") ] },
            { tool_calls: [ call.("\"Boston\"}") ] }
          )

          assert_equal 1, message[:tool_calls].size
          assert_equal "call_1", message[:tool_calls][0][:id]
          assert_equal "function", message[:tool_calls][0][:type]
          assert_equal "get_weather", message[:tool_calls][0][:function][:name]
          assert_equal "{\"city\":\"Boston\"}", message[:tool_calls][0][:function][:arguments]
        end

        test "complete calls without an index or id stay separate calls" do
          message = merge(
            { tool_calls: [ { type: "function", function: { name: "a", arguments: "{}" } },
                            { type: "function", function: { name: "b", arguments: "{}" } } ] }
          )

          assert_equal %w[a b], message[:tool_calls].map { _1[:function][:name] }
        end

        test "indexed calls still merge by index" do
          message = merge(
            { tool_calls: [ { index: 0, id: "call_1", type: "function", function: { name: "a", arguments: "" } } ] },
            { tool_calls: [ { index: 1, id: "call_2", type: "function", function: { name: "b", arguments: "" } } ] },
            { tool_calls: [ { index: 0, function: { arguments: "{}" } } ] }
          )

          assert_equal %w[a b], message[:tool_calls].map { _1[:function][:name] }
          assert_equal [ "{}", "" ], message[:tool_calls].map { _1[:function][:arguments] }
        end
      end
    end
  end
end
