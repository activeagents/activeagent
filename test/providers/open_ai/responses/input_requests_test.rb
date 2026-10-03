# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/responses_provider"

module Providers
  module OpenAI
    module Responses
      # Pausing for user input and resuming, over the Responses API wire
      # format, streamed and not, with and without reasoning items.
      class InputRequestsTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/responses"

        TOOLS = [
          { name: "lookup_order", description: "Look up an order",
            parameters: { type: "object", properties: { order_id: { type: "integer" } }, required: [ "order_id" ] } },
          { name: "issue_refund", description: "Refund an order",
            parameters: { type: "object", properties: { order_id: { type: "integer" }, amount: { type: "integer" } }, required: [ "order_id", "amount" ] } }
        ].freeze

        class RefundAgent < ApplicationAgent
          generate_with :openai, model: "gpt-5-mini", api_key: "test-key"

          class_attribute :calls, default: []

          def triage(stream: false, **options)
            prompt(message: "Refund order 7", instructions: "You handle refunds.", tools: TOOLS, stream:, **options)
          end

          def lookup_order(order_id:)
            calls << :lookup_order
            { order_id:, total: 40 }
          end

          def issue_refund(order_id:, amount:)
            return ActiveAgent::InputRequest.confirm("Refund #{amount} on order #{order_id}?") unless input_answer

            calls << :issue_refund
            { refunded: amount }
          end
        end

        REASONING = { type: "reasoning", id: "rs_1", summary: [ { type: "summary_text", text: "Look the order up, then refund it." } ] }.freeze
        LOOKUP    = { type: "function_call", id: "fc_1", call_id: "call_1", name: "lookup_order",
                      arguments: { order_id: 7 }.to_json, status: "completed" }.freeze
        REFUND    = { type: "function_call", id: "fc_2", call_id: "call_2", name: "issue_refund",
                      arguments: { order_id: 7, amount: 40 }.to_json, status: "completed" }.freeze
        ANSWER    = { type: "message", id: "msg_1", role: "assistant", status: "completed",
                      content: [ { type: "output_text", text: "Refunded.", annotations: [] } ] }.freeze

        USAGE = { input_tokens: 20, output_tokens: 10, total_tokens: 30,
                  input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } }.freeze

        setup do
          RefundAgent.calls = []
        end

        def response_body(*output)
          { id: "resp_#{SecureRandom.hex(4)}", object: "response", created_at: 1_761_502_994, status: "completed",
            model: "gpt-5-mini", output:, parallel_tool_calls: true, tool_choice: "auto", tools: [], usage: USAGE }
        end

        # The events of a real Responses stream for the same response.
        def sse(body)
          shell  = body.merge(status: "in_progress", output: [], usage: nil)
          events = [ { type: "response.created", response: shell }, { type: "response.in_progress", response: shell } ]

          body[:output].each_with_index do |item, output_index|
            ids = { item_id: item[:id], output_index: }

            case item[:type]
            when "message"
              text = item[:content].first[:text]
              part = { type: "output_text", text: "", annotations: [] }

              events << { type: "response.output_item.added", output_index:, item: item.merge(status: "in_progress", content: []) }
              events << { type: "response.content_part.added", **ids, content_index: 0, part: }
              events << { type: "response.output_text.delta", **ids, content_index: 0, delta: text, logprobs: [] }
              events << { type: "response.output_text.done", **ids, content_index: 0, text:, logprobs: [] }
              events << { type: "response.content_part.done", **ids, content_index: 0, part: part.merge(text:) }
            when "function_call"
              events << { type: "response.output_item.added", output_index:, item: item.merge(status: "in_progress", arguments: "") }
              events << { type: "response.function_call_arguments.delta", **ids, delta: item[:arguments] }
              events << { type: "response.function_call_arguments.done", **ids, arguments: item[:arguments] }
            when "reasoning"
              text = item[:summary].first[:text]

              events << { type: "response.output_item.added", output_index:, item: item.merge(summary: []) }
              events << { type: "response.reasoning_summary_part.added", **ids, summary_index: 0, part: { type: "summary_text", text: "" } }
              events << { type: "response.reasoning_summary_text.delta", **ids, summary_index: 0, delta: text }
              events << { type: "response.reasoning_summary_text.done", **ids, summary_index: 0, text: }
              events << { type: "response.reasoning_summary_part.done", **ids, summary_index: 0, part: { type: "summary_text", text: } }
            end

            events << { type: "response.output_item.done", output_index:, item: }
          end

          events << { type: "response.completed", response: body }
          events.each_with_index.map { |event, index| "event: #{event[:type]}\ndata: #{event.merge(sequence_number: index).to_json}\n\n" }.join
        end

        def stub_responses(*bodies, stream: false)
          responses = bodies.map do |body|
            if stream
              { status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse(body) }
            else
              { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
            end
          end

          @request_bodies = []
          stub_request(:post, ENDPOINT)
            .with { |request| @request_bodies << JSON.parse(request.body) }
            .to_return(*responses)
        end

        attr_reader :request_bodies

        test "a streamed tool loop that does not pause runs each tool once" do
          stub_responses(response_body(REASONING, LOOKUP), response_body(ANSWER), stream: true)

          response = RefundAgent.triage(stream: true).generate_now

          assert_not response.awaiting_input?
          assert_equal "Refunded.", response.message.content
          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 2
        end
      end
    end
  end
end
