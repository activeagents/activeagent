# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/open_ai/responses_provider"

# A provider whose tool loop calls `call_tool_function` itself, rather than
# through dispatch_tool_calls, cannot pause. A tool that asks for input, or
# one that needs approval, raises there rather than sending the request
# object to the model or running without anyone's approval.
class InputRequestsUnsupportedTest < ActiveSupport::TestCase
  include WebMock::API

  # The Responses tool loop as it was before it could pause.
  class UndispatchedProvider < ActiveAgent::Providers::OpenAI::ResponsesProvider
    def self.name = "ActiveAgent::Providers::OpenAI::ResponsesProvider"

    def process_function_calls(api_function_calls)
      api_function_calls.each do |api_function_call|
        output = process_tool_call_function(api_function_call).to_json

        message_stack.push({ type: "function_call_output", call_id: api_function_call[:call_id], output: })
      end
    end
  end

  REFUND_TOOL = { name: "issue_refund", description: "Refund an order", parameters: { type: "object", properties: {} } }.freeze

  setup do
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      { status: 200, headers: { "Content-Type" => "application/json" }, body: response_body(function_call).to_json },
      { status: 200, headers: { "Content-Type" => "application/json" }, body: response_body(answer).to_json }
    )
  end

  def response_body(*output)
    { id: "resp_1", object: "response", created_at: 1_761_502_994, status: "completed", model: "gpt-4o-mini",
      output:, usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } }
  end

  def function_call = { type: "function_call", id: "fc_1", call_id: "inner_call", name: "issue_refund", arguments: "{}", status: "completed" }

  def answer = { type: "message", id: "msg_1", role: "assistant", status: "completed", content: [ { type: "output_text", text: "Done.", annotations: [] } ] }

  def provider(tools_function, **options)
    UndispatchedProvider.new(
      service: "OpenAI", api_key: "test-key", model: "gpt-4o-mini",
      messages: [ { role: "user", content: "Refund order 7" } ],
      tools: [ REFUND_TOOL ], tools_function:, **options
    )
  end

  test "a tool that asks for input raises" do
    error = assert_raises(ActiveAgent::InputRequest::UnsupportedProviderError) do
      provider(->(*, **) { ActiveAgent::InputRequest.confirm("Refund 40?") }).prompt
    end

    assert_match(/OpenAI::Responses cannot pause/, error.message)
  end

  test "a tool that needs approval raises before it runs" do
    ran = []

    error = assert_raises(ActiveAgent::InputRequest::UnsupportedProviderError) do
      provider(->(*, **) { ran << :issue_refund }, requires_approval: [ :issue_refund ]).prompt
    end

    assert_match(/issue_refund, which needs approval/, error.message)
    assert_empty ran
  end

  test "a tool does not read the answer of the call that started its generation" do
    seen = []
    gated = lambda do |*, **|
      call_id = ActiveAgent::InputRequest.current_tool_call_id
      answer  = ActiveAgent::InputRequest.answer_for(call_id)
      seen << [ call_id, answer ]
      answer ? { refunded: 40 } : ActiveAgent::InputRequest.confirm("Refund 40?")
    end

    # An approved call of an outer generation starts this one.
    assert_raises(ActiveAgent::InputRequest::UnsupportedProviderError) do
      ActiveAgent::InputRequest.dispatching("outer_call", answer: true) { provider(gated).prompt }
    end
    assert_equal [ [ nil, nil ] ], seen
  end
end
