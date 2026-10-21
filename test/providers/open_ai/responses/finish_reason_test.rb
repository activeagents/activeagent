# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/responses_provider"

module Providers
  module OpenAI
    module Responses
      # The Responses API reports why it stopped as the response's `status`,
      # plus `incomplete_details.reason` when it was cut short.
      class FinishReasonTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/responses"

        MESSAGE = { id: "msg_1", type: "message", role: "assistant", status: "completed",
                    content: [ { type: "output_text", text: "Hi", annotations: [] } ] }.freeze
        RESPONSE = { id: "resp_1", object: "response", created_at: 1_761_502_994, model: "gpt-5",
                     parallel_tool_calls: true, tool_choice: "auto", tools: [], output: [ MESSAGE ],
                     usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2,
                              input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } }.freeze

        def provider(stream:)
          ActiveAgent::Providers::OpenAI::ResponsesProvider.new(
            service: "OpenAI",
            api_key: "test-key",
            model: "gpt-5",
            stream:,
            messages: [ { role: "user", content: "Hello" } ],
            stream_broadcaster: ->(_message, _delta, _event_type) { }
          )
        end

        def stream_finishing_with(response)
          type = response[:status] == "incomplete" ? "response.incomplete" : "response.completed"
          events = [
            { type: "response.created", response: RESPONSE.merge(status: "in_progress", output: []) },
            { type: "response.output_item.added", output_index: 0, item: MESSAGE.merge(status: "in_progress", content: []) },
            { type: "response.output_item.done", output_index: 0, item: MESSAGE },
            { type:, response: }
          ]
          body = events.each_with_index.map { |event, index| "event: #{event[:type]}\ndata: #{event.merge(sequence_number: index).to_json}\n\n" }.join
          stub_request(:post, ENDPOINT).to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body:)

          provider(stream: true).prompt
        end

        test "a streamed response reports the status it completed with" do
          assert_equal "completed", stream_finishing_with(RESPONSE.merge(status: "completed")).finish_reason
        end

        test "a streamed response cut short reports why" do
          response = RESPONSE.merge(status: "incomplete", incomplete_details: { reason: "max_output_tokens" })

          assert_equal "max_output_tokens", stream_finishing_with(response).finish_reason
        end

        test "a response that was not streamed reports the status it completed with" do
          stub_request(:post, ENDPOINT).to_return(
            status: 200, headers: { "Content-Type" => "application/json" },
            body: RESPONSE.merge(status: "completed").to_json
          )

          assert_equal "completed", provider(stream: false).prompt.finish_reason
        end
      end
    end
  end
end
