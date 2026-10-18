# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    # A streamed answer that cites a document, end to end over the Messages
    # wire format: the citations_delta events are skipped while streaming, and
    # the citations reach the final message with the completed text block.
    class StreamingCitationsTest < ActiveSupport::TestCase
      include WebMock::API

      ENDPOINT = "https://api.anthropic.com/v1/messages"

      CITATION = {
        type: "char_location",
        cited_text: "The grass is green.",
        document_index: 0,
        document_title: "Facts",
        start_char_index: 0,
        end_char_index: 19
      }.freeze

      def sse
        message = { id: "msg_1", type: "message", role: "assistant", model: "claude-sonnet-4-5", content: [],
                    stop_reason: nil, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 1 } }
        events = [
          [ "message_start", { type: "message_start", message: } ],
          [ "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "", citations: [] } } ],
          [ "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "citations_delta", citation: CITATION } } ],
          [ "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "The grass is green." } } ],
          [ "content_block_stop", { type: "content_block_stop", index: 0 } ],
          [ "message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: nil }, usage: { output_tokens: 6 } } ],
          [ "message_stop", { type: "message_stop" } ]
        ]

        events.map { |name, data| "event: #{name}\ndata: #{data.to_json}\n\n" }.join
      end

      test "a streamed answer keeps its citations in the final message" do
        stub_request(:post, ENDPOINT)
          .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse)

        closed_message = nil
        provider = ActiveAgent::Providers::AnthropicProvider.new(
          service: "Anthropic",
          model: "claude-sonnet-4-5",
          api_key: "test-key",
          stream: true,
          messages: [ { role: "user", content: "What color is the grass?" } ],
          stream_broadcaster: ->(message, _delta, event_type) { closed_message = message if event_type == :close }
        )

        response = provider.prompt

        assert_equal "The grass is green.", response.message.content

        # The final provider message, handed over at stream close, has the
        # completed text block with its citations.
        text_block = closed_message.deep_symbolize_keys[:content].first
        assert_equal "text", text_block[:type].to_s
        assert_equal "The grass is green.", text_block[:text]
        assert_equal 1, text_block[:citations].size
        assert_equal "The grass is green.", text_block[:citations].first[:cited_text]
        assert_equal "Facts", text_block[:citations].first[:document_title]
      end
    end
  end
end
