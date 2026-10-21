# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    # A streamed generation has no response body, so why it stopped has to be
    # read from the message_delta event and reach the response.
    class StreamingFinishReasonTest < ActiveSupport::TestCase
      include WebMock::API

      ENDPOINT = "https://api.anthropic.com/v1/messages"

      def sse(stop_reason)
        message = { id: "msg_1", type: "message", role: "assistant", model: "claude-sonnet-4-5", content: [],
                    stop_reason: nil, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 1 } }
        events = [
          [ "message_start", { type: "message_start", message: } ],
          [ "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } ],
          [ "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "Hello" } } ],
          [ "content_block_stop", { type: "content_block_stop", index: 0 } ],
          [ "message_delta", { type: "message_delta", delta: { stop_reason:, stop_sequence: nil }, usage: { output_tokens: 6 } } ],
          [ "message_stop", { type: "message_stop" } ]
        ]

        events.map { |name, data| "event: #{name}\ndata: #{data.to_json}\n\n" }.join
      end

      def stream_prompt(stop_reason)
        stub_request(:post, ENDPOINT)
          .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse(stop_reason))

        ActiveAgent::Providers::AnthropicProvider.new(
          service: "Anthropic",
          model: "claude-sonnet-4-5",
          api_key: "test-key",
          stream: true,
          messages: [ { role: "user", content: "Hi" } ],
          stream_broadcaster: ->(_message, _delta, _event_type) { }
        ).prompt
      end

      test "a streamed generation reports why it stopped" do
        assert_equal "end_turn", stream_prompt("end_turn").finish_reason
      end

      test "a streamed generation cut off at the token limit reports max_tokens" do
        assert_equal "max_tokens", stream_prompt("max_tokens").stop_reason
      end
    end
  end
end
