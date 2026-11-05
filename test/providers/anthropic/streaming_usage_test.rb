# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    # A streamed generation has no response body, so the token counts have to
    # be collected from the message_start and message_delta events.
    class StreamingUsageTest < ActiveSupport::TestCase
      include WebMock::API

      ENDPOINT = "https://api.anthropic.com/v1/messages"

      def sse
        message = { id: "msg_1", type: "message", role: "assistant", model: "claude-sonnet-4-5", content: [],
                    stop_reason: nil, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 1 } }
        events = [
          [ "message_start", { type: "message_start", message: } ],
          [ "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } ],
          [ "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello" } } ],
          [ "content_block_stop", { type: "content_block_stop", index: 0 } ],
          [ "message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: nil }, usage: { output_tokens: 6 } } ],
          [ "message_stop", { type: "message_stop" } ]
        ]

        events.map { |name, data| "event: #{name}\ndata: #{data.to_json}\n\n" }.join
      end

      test "a streamed generation reports its token usage" do
        stub_request(:post, ENDPOINT)
          .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse)

        response = ActiveAgent::Providers::AnthropicProvider.new(
          service: "Anthropic",
          model: "claude-sonnet-4-5",
          api_key: "test-key",
          stream: true,
          messages: [ { role: "user", content: "Hi" } ],
          stream_broadcaster: ->(_message, _delta, _event_type) { }
        ).prompt

        assert_not_nil response.usage
        assert_equal 20, response.usage.input_tokens
        assert_equal 6, response.usage.output_tokens
      end
    end
  end
end
