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

        def resume(paused, answers, **options)
          RefundAgent.triage(**options).resume_now(checkpoint: JSON.parse(paused.checkpoint.to_json), answers:)
        end

        # The resumed request carries the conversation once, each reasoning
        # item before the function calls it led to, then one
        # function_call_output per call, in call order.
        def assert_resumed_wire_format(body, reasoning: false)
          input = body["input"]
          types = input.map { _1["type"] || _1["role"] }

          expected = [ "user", *("reasoning" if reasoning), "function_call", "function_call", "function_call_output", "function_call_output" ]
          assert_equal expected, types
          assert_equal "You handle refunds.", body["instructions"]
          assert_equal "rs_1", input[1]["id"] if reasoning
          assert_equal [ [ "call_1", { order_id: 7, total: 40 }.to_json ], [ "call_2", { refunded: 40 }.to_json ] ],
                       input.select { _1["type"] == "function_call_output" }.map { [ _1["call_id"], _1["output"] ] }
        end

        test "a paused turn sends nothing back, and its completed result waits in the checkpoint" do
          stub_responses(response_body(LOOKUP, REFUND))

          paused = RefundAgent.triage.generate_now

          assert paused.awaiting_input?
          request = paused.input_requests.sole
          assert_equal [ "call_2", "issue_refund", { "order_id" => 7, "amount" => 40 } ], [ request.tool_call_id, request.tool_name, request.arguments ]
          assert_equal({ "call_1" => { "order_id" => 7, "total" => 40 } }, paused.checkpoint["completed_results"])
          assert_equal [ "user", "function_call", "function_call" ], paused.checkpoint["messages"].map { _1["type"] || _1["role"] }
          assert_equal 2, paused.checkpoint["tool_call_turn_size"]
          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 1
        end

        test "resuming sends every function_call_output in call order" do
          stub_responses(response_body(LOOKUP, REFUND), response_body(ANSWER))
          paused = RefundAgent.triage.generate_now

          response = resume(paused, { "call_2" => true })

          assert_not response.awaiting_input?
          assert_equal "Refunded.", response.message.content
          assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls
          assert_resumed_wire_format(request_bodies.last)
        end

        test "a declined call tells the model the user declined, without running the tool" do
          stub_responses(response_body(LOOKUP, REFUND), response_body(ANSWER))
          paused = RefundAgent.triage.generate_now

          resume(paused, { "call_2" => false })

          assert_equal [ :lookup_order ], RefundAgent.calls
          output = request_bodies.last["input"].find { _1["call_id"] == "call_2" && _1["type"] == "function_call_output" }
          assert_equal ActiveAgent::InputRequest::DECLINED_RESULT.to_json, output["output"]
        end

        test "a generation that pauses again after a resume replays every earlier item once" do
          second_refund = REFUND.merge(id: "fc_3", call_id: "call_3", arguments: { order_id: 8, amount: 15 }.to_json)
          stub_responses(response_body(REASONING, LOOKUP, REFUND), response_body(REASONING.merge(id: "rs_2"), second_refund), response_body(ANSWER))
          first = RefundAgent.triage.generate_now

          second = resume(first, { "call_2" => true })

          assert second.awaiting_input?
          assert_equal [ "call_3" ], second.input_requests.map(&:tool_call_id)
          assert_equal 2, second.checkpoint["tool_call_turn_size"]

          resume(second, { "call_3" => true })

          input = request_bodies.last["input"]
          assert_equal %w[user reasoning function_call function_call function_call_output function_call_output reasoning function_call function_call_output],
                       input.map { _1["type"] || _1["role"] }
          assert_equal %w[rs_1 rs_2], input.select { _1["type"] == "reasoning" }.pluck("id")
          assert_equal %w[call_1 call_2 call_3], input.select { _1["type"] == "function_call_output" }.pluck("call_id")
          assert_equal [ :lookup_order, :issue_refund, :issue_refund ], RefundAgent.calls
        end

        test "a checkpoint from a reasoning model resumes with its reasoning item in place" do
          stub_responses(response_body(REASONING, LOOKUP, REFUND), response_body(ANSWER))
          paused = RefundAgent.triage.generate_now

          assert_equal 3, paused.checkpoint["tool_call_turn_size"]

          resume(paused, { "call_2" => true })

          assert_resumed_wire_format(request_bodies.last, reasoning: true)
        end

        test "a streamed pause runs each tool once" do
          stub_responses(response_body(LOOKUP, REFUND), response_body(ANSWER), stream: true)

          paused = RefundAgent.triage(stream: true).generate_now

          assert paused.awaiting_input?
          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 1

          response = resume(paused, { "call_2" => true }, stream: true)

          assert_equal "Refunded.", response.message.content
          assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls
          assert_resumed_wire_format(request_bodies.last)
        end

        test "a streamed response with reasoning items pauses and resumes with them in place" do
          stub_responses(response_body(REASONING, LOOKUP, REFUND), response_body(REASONING.merge(id: "rs_2"), ANSWER), stream: true)

          paused = RefundAgent.triage(stream: true).generate_now

          assert paused.awaiting_input?
          assert_equal [ "user", "reasoning", "function_call", "function_call" ], paused.checkpoint["messages"].map { _1["type"] || _1["role"] }

          response = resume(paused, { "call_2" => true }, stream: true)

          assert_equal "Refunded.", response.message.content
          assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls
          assert_resumed_wire_format(request_bodies.last, reasoning: true)
        end

        # Records the stream and pause callbacks a generation runs.
        class CallbackRefundAgent < RefundAgent
          class_attribute :events, default: []

          on_stream_close { events << :stream_close }
          on_input_request { events << :input_request }
        end

        test "a streamed pause closes the stream once and announces the pause once" do
          stub_responses(response_body(REASONING, LOOKUP, REFUND), stream: true)
          CallbackRefundAgent.events = []
          announced = []
          subscriber = ActiveSupport::Notifications.subscribe("input_requested.active_agent") { announced << _1 }

          paused = CallbackRefundAgent.triage(stream: true).generate_now

          assert paused.awaiting_input?
          assert_equal %i[stream_close input_request], CallbackRefundAgent.events
          assert_equal 1, announced.size
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        test "a streamed tool loop that does not pause runs each tool once" do
          stub_responses(response_body(REASONING, LOOKUP), response_body(ANSWER), stream: true)

          response = RefundAgent.triage(stream: true).generate_now

          assert_not response.awaiting_input?
          assert_equal "Refunded.", response.message.content
          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 2
        end

        test "requires_approval pauses before the tool runs, and an approval runs it" do
          stub_responses(response_body(LOOKUP), response_body(ANSWER))

          paused = RefundAgent.triage(requires_approval: [ :lookup_order ]).generate_now

          assert paused.awaiting_input?
          request = paused.input_requests.sole
          assert_equal [ :confirm, "lookup_order", { "order_id" => 7 } ], [ request.kind, request.tool_name, request.arguments ]
          assert_empty RefundAgent.calls
          assert_not request_bodies.first.key?("requires_approval"), "the approval list is never sent to the API"

          resume(paused, { "call_1" => true }, requires_approval: [ :lookup_order ])

          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 2
        end

        test "a checkpoint from Responses does not resume on Chat Completions" do
          stub_responses(response_body(LOOKUP, REFUND))
          paused = RefundAgent.triage.generate_now

          error = assert_raises(ActiveAgent::InputRequest::ResumeError) do
            resume(paused, { "call_2" => true }, api_version: :chat)
          end

          assert_match "OpenAI::Responses", error.message
          assert_requested :post, ENDPOINT, times: 1
        end
      end
    end
  end
end
