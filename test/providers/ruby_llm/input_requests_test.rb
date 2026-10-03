# frozen_string_literal: true

require "test_helper"
require "ruby_llm"
require "active_agent/providers/ruby_llm_provider"

module Providers
  module RubyLLM
    # Pausing for user input and resuming through RubyLLM, streamed and not.
    # ruby_llm renders the requests, so the assertions read the OpenAI Chat
    # Completions bodies it sends.
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
        generate_with :ruby_llm, model: "gpt-4o-mini"

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

      LOOKUP = { id: "call_1", type: "function", function: { name: "lookup_order", arguments: { order_id: 7 }.to_json } }.freeze
      REFUND = { id: "call_2", type: "function", function: { name: "issue_refund", arguments: { order_id: 7, amount: 40 }.to_json } }.freeze

      USAGE = { prompt_tokens: 20, completion_tokens: 10, total_tokens: 30 }.freeze

      setup do
        RefundAgent.calls = []

        @original_key = ::RubyLLM.config.openai_api_key
        ::RubyLLM.config.openai_api_key = "test-openai-key"
        if ::RubyLLM.config.respond_to?(:openai_protocol)
          @original_protocol = ::RubyLLM.config.openai_protocol
          ::RubyLLM.config.openai_protocol = :chat_completions
        end
      end

      teardown do
        ::RubyLLM.config.openai_api_key = @original_key
        ::RubyLLM.config.openai_protocol = @original_protocol if ::RubyLLM.config.respond_to?(:openai_protocol)
      end

      def completion(tool_calls: nil, content: nil)
        {
          id: "chatcmpl-#{SecureRandom.hex(4)}", object: "chat.completion", created: 1_761_502_994, model: "gpt-4o-mini",
          choices: [ { index: 0, message: { role: "assistant", content:, tool_calls: }.compact, finish_reason: tool_calls ? "tool_calls" : "stop" } ],
          usage: USAGE
        }
      end

      # The chunks of a real Chat Completions stream for the same completion.
      # Under RubyLLM 1.x, each tool call arrives whole in one chunk, because
      # 1.x keys a later argument chunk by its missing id, and the provider
      # then cannot tell which call it extends.
      def sse(body)
        message = body[:choices].first[:message]
        deltas  = [ { role: "assistant", content: message[:content] ? "" : nil }.compact ]

        deltas << { content: message[:content] } if message[:content]
        Array(message[:tool_calls]).each_with_index do |call, index|
          name, arguments = call.dig(:function, :name), call.dig(:function, :arguments)

          if ::RubyLLM::VERSION.to_i >= 2
            deltas << { tool_calls: [ { index:, id: call[:id], type: "function", function: { name:, arguments: "" } } ] }
            deltas << { tool_calls: [ { index:, function: { arguments: } } ] }
          else
            deltas << { tool_calls: [ { index:, id: call[:id], type: "function", function: { name:, arguments: } } ] }
          end
        end

        chunks = deltas.map { { choices: [ { index: 0, delta: _1, finish_reason: nil } ] } }
        chunks << { choices: [ { index: 0, delta: {}, finish_reason: body[:choices].first[:finish_reason] } ] }

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

      def resume(paused, answers, **options)
        RefundAgent.triage(**options).resume_now(checkpoint: JSON.parse(paused.checkpoint.to_json), answers:)
      end

      def assert_resumed_wire_format(body)
        messages = body["messages"]

        assert_includes %w[system developer], messages.first["role"], "ruby_llm sends instructions as a system or developer message"
        assert_equal %w[user assistant tool tool], messages.drop(1).map { _1["role"] }
        assert_equal "You handle refunds.", messages.first["content"]
        assert_equal %w[call_1 call_2], messages[2]["tool_calls"].map { _1["id"] }
        assert_equal [ [ "call_1", { order_id: 7, total: 40 }.to_json ], [ "call_2", { refunded: 40 }.to_json ] ],
                     messages[3..].map { [ _1["tool_call_id"], _1["content"] ] }
      end

      test "a paused turn sends nothing back, and its completed result waits in the checkpoint" do
        stub_completions(completion(tool_calls: [ LOOKUP, REFUND ]))

        paused = RefundAgent.triage.generate_now

        assert paused.awaiting_input?
        request = paused.input_requests.sole
        assert_equal [ "call_2", "issue_refund", { "order_id" => 7, "amount" => 40 } ], [ request.tool_call_id, request.tool_name, request.arguments ]
        assert_equal({ "call_1" => { "order_id" => 7, "total" => 40 } }, paused.checkpoint["completed_results"])
        assert_equal %w[user assistant], paused.checkpoint["messages"].map { _1["role"] }
        assert_equal [ :lookup_order ], RefundAgent.calls
        assert_requested :post, ENDPOINT, times: 1
      end

      test "resuming sends the system prompt once and one tool message per call id, in call order" do
        stub_completions(completion(tool_calls: [ LOOKUP, REFUND ]), completion(content: "Refunded."))
        paused = RefundAgent.triage.generate_now

        response = resume(paused, { "call_2" => true })

        assert_not response.awaiting_input?
        assert_equal "Refunded.", response.message.content
        assert_equal [ :lookup_order, :issue_refund ], RefundAgent.calls
        assert_resumed_wire_format(request_bodies.last)
      end

      test "a generation that pauses again after a resume replays every earlier message once" do
        second_refund = REFUND.merge(id: "call_3", function: { name: "issue_refund", arguments: { order_id: 8, amount: 15 }.to_json })
        stub_completions(completion(tool_calls: [ LOOKUP, REFUND ]), completion(tool_calls: [ second_refund ]), completion(content: "Refunded."))
        first = RefundAgent.triage.generate_now

        second = resume(first, { "call_2" => true })

        assert_equal [ "call_3" ], second.input_requests.map(&:tool_call_id)

        resume(second, { "call_3" => true })

        messages = request_bodies.last["messages"]
        assert_equal %w[user assistant tool tool assistant tool], messages.drop(1).map { _1["role"] }
        assert_equal %w[call_1 call_2 call_3], messages.filter_map { _1["tool_call_id"] }
        assert_equal [ :lookup_order, :issue_refund, :issue_refund ], RefundAgent.calls
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

      test "requires_approval pauses before the tool runs, and a decline never runs it" do
        stub_completions(completion(tool_calls: [ LOOKUP ]), completion(content: "Not refunded."))

        paused = RefundAgent.triage(requires_approval: [ :lookup_order ]).generate_now

        assert_equal [ :confirm, "lookup_order" ], [ paused.input_requests.sole.kind, paused.input_requests.sole.tool_name ]

        resume(paused, { "call_1" => false }, requires_approval: [ :lookup_order ])

        assert_empty RefundAgent.calls
        assert_equal ActiveAgent::InputRequest::DECLINED_RESULT.to_json, request_bodies.last["messages"].last["content"]
      end
    end
  end
end
