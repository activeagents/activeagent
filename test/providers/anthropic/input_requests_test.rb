# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic_provider"

module Providers
  module Anthropic
    # Pausing for user input and resuming, over the Anthropic Messages wire
    # format, streamed and not.
    class InputRequestsTest < ActiveSupport::TestCase
      include WebMock::API

      ENDPOINT = "https://api.anthropic.com/v1/messages"

      TOOLS = [
        { name: "lookup_order", description: "Look up an order",
          parameters: { type: "object", properties: { order_id: { type: "integer" } }, required: [ "order_id" ] } },
        { name: "issue_refund", description: "Refund an order",
          parameters: { type: "object", properties: { order_id: { type: "integer" }, amount: { type: "integer" } }, required: [ "order_id", "amount" ] } }
      ].freeze

      class RefundAgent < ApplicationAgent
        generate_with :anthropic, model: "claude-sonnet-4-5", api_key: "test-key"

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

      LOOKUP = { type: "tool_use", id: "toolu_1", name: "lookup_order", input: { order_id: 7 } }.freeze
      REFUND = { type: "tool_use", id: "toolu_2", name: "issue_refund", input: { order_id: 7, amount: 40 } }.freeze
      ANSWER = { type: "text", text: "Refunded." }.freeze

      setup do
        RefundAgent.calls = []
      end

      def assistant_message(*content)
        stop_reason = content.any? { |block| block[:type] == "tool_use" } ? "tool_use" : "end_turn"

        { id: "msg_#{SecureRandom.hex(4)}", type: "message", role: "assistant", model: "claude-sonnet-4-5",
          content:, stop_reason:, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 10 } }
      end

      # The events of a real Messages stream for the same message.
      def sse(message)
        events = [ [ "message_start", { type: "message_start", message: message.merge(content: [], stop_reason: nil) } ] ]

        message[:content].each_with_index do |block, index|
          if block[:type] == "tool_use"
            events << [ "content_block_start", { type: "content_block_start", index:, content_block: block.merge(input: {}) } ]
            events << [ "content_block_delta", { type: "content_block_delta", index:, delta: { type: "input_json_delta", partial_json: block[:input].to_json } } ]
          else
            events << [ "content_block_start", { type: "content_block_start", index:, content_block: { type: "text", text: "" } } ]
            events << [ "content_block_delta", { type: "content_block_delta", index:, delta: { type: "text_delta", text: block[:text] } } ]
          end
          events << [ "content_block_stop", { type: "content_block_stop", index: } ]
        end

        events << [ "message_delta", { type: "message_delta", delta: { stop_reason: message[:stop_reason], stop_sequence: nil }, usage: message[:usage] } ]
        events << [ "message_stop", { type: "message_stop" } ]

        events.map { |name, data| "event: #{name}\ndata: #{data.to_json}\n\n" }.join
      end

      def stub_messages(*messages, stream: false)
        responses = messages.map do |body|
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

      test "a paused turn sends nothing back, and its completed result waits in the checkpoint" do
        stub_messages(assistant_message(LOOKUP, REFUND))

        paused = RefundAgent.triage.generate_now

        assert paused.awaiting_input?
        assert_equal [ "toolu_2" ], paused.input_requests.map(&:tool_call_id)
        assert_equal [ :lookup_order ], RefundAgent.calls
        assert_equal({ "toolu_1" => { "order_id" => 7, "total" => 40 } }, paused.checkpoint["completed_results"])
        assert_equal %w[user assistant], paused.checkpoint["messages"].map { _1["role"] }
        assert_requested :post, ENDPOINT, times: 1
      end

      test "resuming sends one tool_use turn followed by one user turn with every tool_result in call order" do
        stub_messages(assistant_message(LOOKUP, REFUND), assistant_message(ANSWER))
        paused = RefundAgent.triage.generate_now

        response = resume(paused, { "toolu_2" => true })

        assert_equal "Refunded.", response.message.content
        assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls

        resumed = request_bodies.last
        assert_equal "You handle refunds.", resumed["system"]
        assert_equal %w[user assistant user], resumed["messages"].map { _1["role"] }
        assert_equal %w[toolu_1 toolu_2], resumed["messages"][1]["content"].map { _1["id"] }
        assert_equal [ [ "toolu_1", { order_id: 7, total: 40 }.to_json ], [ "toolu_2", { refunded: 40 }.to_json ] ],
                     resumed["messages"][2]["content"].map { [ _1["tool_use_id"], _1["content"] ] }
      end

      test "a streamed pause runs each tool once" do
        stub_messages(assistant_message(LOOKUP, REFUND), assistant_message(ANSWER), stream: true)

        paused = RefundAgent.triage(stream: true).generate_now

        assert paused.awaiting_input?
        assert_equal [ :lookup_order ], RefundAgent.calls
        assert_requested :post, ENDPOINT, times: 1

        response = resume(paused, { "toolu_2" => true }, stream: true)

        assert_equal "Refunded.", response.message.content
        assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls
        assert_equal %w[toolu_1 toolu_2], request_bodies.last["messages"][2]["content"].map { _1["tool_use_id"] }
      end

      test "a streamed tool loop that does not pause runs each tool once" do
        stub_messages(assistant_message(LOOKUP), assistant_message(ANSWER), stream: true)

        response = RefundAgent.triage(stream: true).generate_now

        assert_not response.awaiting_input?
        assert_equal "Refunded.", response.message.content
        assert_equal [ :lookup_order ], RefundAgent.calls
        assert_requested :post, ENDPOINT, times: 2
      end

      test "a pause is not retried as a malformed JSON response" do
        stub_messages(assistant_message(REFUND))

        paused = RefundAgent.triage(response_format: :json_object).generate_now

        assert paused.awaiting_input?
        assert_requested :post, ENDPOINT, times: 1
      end

      test "resuming clears a tool_choice that forced the paused call" do
        stub_messages(assistant_message(REFUND), assistant_message(ANSWER))
        paused = RefundAgent.triage(tool_choice: "required").generate_now

        resume(paused, { "toolu_2" => true }, tool_choice: "required")

        assert_equal "any", request_bodies.first.dig("tool_choice", "type")
        assert_nil request_bodies.last["tool_choice"]
      end
    end
  end
end
