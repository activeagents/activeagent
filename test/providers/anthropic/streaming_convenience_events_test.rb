# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    # Tests for higher-level convenience events emitted by the anthropic gem's
    # MessageStream (PR #299). These events are no-ops since the underlying data
    # is already handled via :content_block_delta, but they must not raise.
    class StreamingConvenienceEventsTest < ActiveSupport::TestCase
      setup do
        @provider = ActiveAgent::Providers::AnthropicProvider.new(
          service: "Anthropic",
          model: "claude-sonnet-4-5",
          messages: [ { role: "user", content: "Hello" } ],
          stream_broadcaster: ->(message, delta, event_type) { }
        )

        @provider.send(:message_stack).push({
          role: "assistant",
          content: [ { type: "text", text: "" } ]
        })
      end

      MockEvent = Struct.new(:type, keyword_init: true) do
        def [](key)
          send(key) if respond_to?(key)
        end
      end

      test "handles :text event without raising" do
        event = MockEvent.new(type: :text)

        assert_nothing_raised do
          @provider.send(:process_stream_chunk, event)
        end
      end

      test "handles :input_json event without raising" do
        event = MockEvent.new(type: :input_json)

        assert_nothing_raised do
          @provider.send(:process_stream_chunk, event)
        end
      end

      test "handles :citation event without raising" do
        event = MockEvent.new(type: :citation)

        assert_nothing_raised do
          @provider.send(:process_stream_chunk, event)
        end
      end
    end
  end
end
