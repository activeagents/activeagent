# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    class StreamingEventsTest < ActiveSupport::TestCase
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

      test "handles :signature event without raising" do
        event = MockEvent.new(type: :signature)

        assert_nothing_raised do
          @provider.send(:process_stream_chunk, event)
        end
      end

      test "handles :thinking event without raising" do
        event = MockEvent.new(type: :thinking)

        assert_nothing_raised do
          @provider.send(:process_stream_chunk, event)
        end
      end
    end
  end
end
