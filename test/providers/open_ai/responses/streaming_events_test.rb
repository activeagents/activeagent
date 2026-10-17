# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/responses_provider"

module Providers
  module OpenAI
    module Responses
      # Streams that end without a plain response.completed: an answer cut
      # short by max_output_tokens, and a refusal.
      class StreamingEventsTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/responses"

        class StreamAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4.1", api_key: "test-key"

          def ask
            prompt(message: "Tell me about grass.", stream: true)
          end
        end

        USAGE = { input_tokens: 10, output_tokens: 5, total_tokens: 15,
                  input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } }.freeze

        # A stream of one message whose part is `part` (output_text or refusal),
        # ending with `terminal` (e.g. "response.incomplete").
        def sse_body(part_events:, final_part:, terminal:, status:, incomplete_details: nil)
          response = { id: "resp_1", object: "response", created_at: 1_761_502_994, model: "gpt-4.1",
                       parallel_tool_calls: true, tool_choice: "auto", tools: [] }
          message = { id: "msg_1", type: "message", role: "assistant", status: status, content: [ final_part ] }
          ids = { item_id: "msg_1", output_index: 0, content_index: 0 }
          empty_part = final_part.merge(final_part.key?(:text) ? { text: "" } : { refusal: "" })

          events = [
            { type: "response.created", response: response.merge(status: "in_progress", output: []) },
            { type: "response.output_item.added", output_index: 0, item: message.merge(status: "in_progress", content: []) },
            { type: "response.content_part.added", **ids, part: empty_part },
            *part_events.map { _1.merge(ids) },
            { type: "response.content_part.done", **ids, part: final_part },
            { type: "response.output_item.done", output_index: 0, item: message },
            { type: terminal, response: response.merge(status:, output: [ message ], usage: USAGE, incomplete_details:) }
          ]
          events.each_with_index.map { |event, index| "event: #{event[:type]}\ndata: #{event.merge(sequence_number: index).to_json}\n\n" }.join
        end

        def stub_stream(body)
          stub_request(:post, ENDPOINT)
            .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body:)
        end

        test "a streamed answer cut short by max_output_tokens keeps its partial text" do
          text = "Grass is green because"
          stub_stream(sse_body(
            part_events: [
              { type: "response.output_text.delta", delta: text, logprobs: [] },
              { type: "response.output_text.done", text:, logprobs: [] }
            ],
            final_part: { type: "output_text", text:, annotations: [] },
            terminal: "response.incomplete", status: "incomplete",
            incomplete_details: { reason: "max_output_tokens" }
          ))

          response = StreamAgent.ask.generate_now

          assert_equal text, response.message.content
        end
      end
    end
  end
end
