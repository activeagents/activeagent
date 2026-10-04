# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/chat_provider"

module Providers
  module OpenAI
    module Chat
      # Pausing for user input and resuming, over the Chat Completions wire
      # format, streamed and not.
      class InputRequestsTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/chat/completions"

        TOOLS = [
          { name: "lookup_order", description: "Look up an order",
            parameters: { type: "object", properties: { order_id: { type: "integer" } }, required: [ "order_id" ] } },
          { name: "issue_refund", description: "Refund an order",
            parameters: { type: "object", properties: { order_id: { type: "integer" }, amount: { type: "integer" } }, required: [ "order_id", "amount" ] } }
        ].freeze

        class RefundAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o-mini", api_key: "test-key", api_version: :chat

          class_attribute :calls, default: []

          def triage(stream: false)
            prompt(message: "Refund order 7", instructions: "You handle refunds.", tools: TOOLS, stream:)
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

        LOOKUP = { id: "call_1", type: "function", function: { name: "lookup_order", arguments: { order_id: 7 }.to_json } }.freeze
        REFUND = { id: "call_2", type: "function", function: { name: "issue_refund", arguments: { order_id: 7, amount: 40 }.to_json } }.freeze

        USAGE = { prompt_tokens: 20, completion_tokens: 10, total_tokens: 30 }.freeze

        setup do
          RefundAgent.calls = []
        end

        def completion(tool_calls: nil, content: nil)
          {
            id: "chatcmpl-#{SecureRandom.hex(4)}", object: "chat.completion", created: 1_761_502_994, model: "gpt-4o-mini",
            choices: [ { index: 0, message: { role: "assistant", content:, tool_calls: }.compact, finish_reason: tool_calls ? "tool_calls" : "stop" } ],
            usage: USAGE
          }
        end

        # The chunks of a real Chat Completions stream for the same completion.
        def sse(body)
          message = body[:choices].first[:message]
          deltas  = [ { role: "assistant", content: message[:content] ? "" : nil }.compact ]

          deltas << { content: message[:content] } if message[:content]
          Array(message[:tool_calls]).each_with_index do |call, index|
            deltas << { tool_calls: [ { index:, id: call[:id], type: "function", function: { name: call.dig(:function, :name), arguments: "" } } ] }
            deltas << { tool_calls: [ { index:, function: { arguments: call.dig(:function, :arguments) } } ] }
          end

          chunks = deltas.map { { choices: [ { index: 0, delta: _1, finish_reason: nil } ] } }
          chunks << { choices: [ { index: 0, delta: {}, finish_reason: body[:choices].first[:finish_reason] } ] }
          chunks << { choices: [], usage: USAGE }

          envelope = { id: body[:id], object: "chat.completion.chunk", created: body[:created], model: body[:model] }
          chunks.map { "data: #{envelope.merge(_1).to_json}\n\n" }.join + "data: [DONE]\n\n"
        end

        def stub_completions(*bodies, stream: false)
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

        def resume(paused, answers, stream: false)
          RefundAgent.triage(stream:).resume_now(checkpoint: JSON.parse(paused.checkpoint.to_json), answers:)
        end

        def assert_resumed_wire_format(body)
          roles = body["messages"].map { _1["role"] }
          assert_equal %w[developer user assistant tool tool], roles
          assert_equal "You handle refunds.", body["messages"].first["content"]
          assert_equal %w[call_1 call_2], body["messages"][2]["tool_calls"].map { _1["id"] }
          assert_equal [ [ "call_1", { order_id: 7, total: 40 }.to_json ], [ "call_2", { refunded: 40 }.to_json ] ],
                       body["messages"][3..].map { [ _1["tool_call_id"], _1["content"] ] }
        end

        test "the checkpoint keeps the conversation without the instructions' developer message" do
          stub_completions(completion(tool_calls: [ LOOKUP, REFUND ]))

          paused = RefundAgent.triage.generate_now

          assert paused.awaiting_input?
          assert_equal %w[user assistant], paused.checkpoint["messages"].map { _1["role"] }
          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 1
        end

        test "resuming sends one developer message and a tool message per call id, in call order" do
          stub_completions(completion(tool_calls: [ LOOKUP, REFUND ]), completion(content: "Refunded."))
          paused = RefundAgent.triage.generate_now

          response = resume(paused, { "call_2" => true })

          assert_equal "Refunded.", response.message.content
          assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls
          assert_resumed_wire_format(request_bodies.last)
        end

        test "a streamed pause runs each tool once" do
          stub_completions(completion(tool_calls: [ LOOKUP, REFUND ]), completion(content: "Refunded."), stream: true)

          paused = RefundAgent.triage(stream: true).generate_now

          assert paused.awaiting_input?
          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 1

          response = resume(paused, { "call_2" => true }, stream: true)

          assert_equal "Refunded.", response.message.content
          assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls
          assert_resumed_wire_format(request_bodies.last)
        end

        test "a streamed tool loop that does not pause runs each tool once" do
          stub_completions(completion(tool_calls: [ LOOKUP ]), completion(content: "Refunded."), stream: true)

          response = RefundAgent.triage(stream: true).generate_now

          assert_not response.awaiting_input?
          assert_equal [ :lookup_order ], RefundAgent.calls
          assert_requested :post, ENDPOINT, times: 2
        end
      end
    end
  end
end
