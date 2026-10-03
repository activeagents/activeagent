# frozen_string_literal: true

require "test_helper"
require "ruby_llm"
require "active_agent/providers/ruby_llm_provider"
require_relative "../../lib/active_agent/providers/open_ai/responses_provider"

# The OpenAI Responses and RubyLLM tool loops cannot pause yet. A tool that
# returns an InputRequest under them raises, rather than sending the request
# object to the model as if it were the tool's result.
class InputRequestsUnsupportedTest < ActiveSupport::TestCase
  include WebMock::API

  ASK = ->(*, **) { ActiveAgent::InputRequest.confirm("Refund 40?") }

  REFUND_TOOL = {
    type: "function",
    function: { name: "issue_refund", description: "Refund an order", parameters: { type: "object", properties: {} } }
  }.freeze

  test "OpenAI Responses raises when a tool asks for input" do
    stub = stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: "resp_1", object: "response", created_at: 1_761_502_994, status: "completed", model: "gpt-4o-mini",
        output: [ { type: "function_call", id: "fc_1", call_id: "call_1", name: "issue_refund", arguments: "{}", status: "completed" } ],
        usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
      }.to_json
    )

    provider = ActiveAgent::Providers::OpenAI::ResponsesProvider.new(
      service: "OpenAI", api_key: "test-key", model: "gpt-4o-mini",
      messages: [ { role: "user", content: "Refund order 7" } ],
      tools: [ { name: "issue_refund", description: "Refund an order", parameters: { type: "object", properties: {} } } ],
      tools_function: ASK
    )

    error = assert_raises(ActiveAgent::InputRequest::UnsupportedProviderError) { provider.prompt }
    assert_match(/OpenAI::Responses cannot pause/, error.message)
    assert_requested stub, times: 1
  end

  test "a tool under a provider that cannot pause does not read the answer of the call that started it" do
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: "resp_1", object: "response", created_at: 1_761_502_994, status: "completed", model: "gpt-4o-mini",
        output: [ { type: "function_call", id: "fc_1", call_id: "inner_call", name: "issue_refund", arguments: "{}", status: "completed" } ],
        usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
      }.to_json
    )

    seen = []
    gated = lambda do |*, **|
      call_id = ActiveAgent::InputRequest.current_tool_call_id
      answer  = ActiveAgent::InputRequest.answer_for(call_id)
      seen << [ call_id, answer ]
      answer ? { refunded: 40 } : ActiveAgent::InputRequest.confirm("Refund 40?")
    end

    provider = ActiveAgent::Providers::OpenAI::ResponsesProvider.new(
      service: "OpenAI", api_key: "test-key", model: "gpt-4o-mini",
      messages: [ { role: "user", content: "Refund order 7" } ],
      tools: [ { name: "issue_refund", description: "Refund an order", parameters: { type: "object", properties: {} } } ],
      tools_function: gated
    )

    # An approved call of an outer generation starts this one.
    assert_raises(ActiveAgent::InputRequest::UnsupportedProviderError) do
      ActiveAgent::InputRequest.dispatching("outer_call", answer: true) { provider.prompt }
    end
    assert_equal [ [ nil, nil ] ], seen
  end

  test "RubyLLM raises when a tool asks for input" do
    original_key = RubyLLM.config.openai_api_key
    original_protocol = RubyLLM.config.openai_protocol if RubyLLM.config.respond_to?(:openai_protocol)
    RubyLLM.config.openai_api_key = "test-openai-key"
    RubyLLM.config.openai_protocol = :chat_completions if RubyLLM.config.respond_to?(:openai_protocol)

    stub = stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        id: "chatcmpl-1", object: "chat.completion", model: "gpt-4o-mini",
        choices: [ { index: 0, finish_reason: "tool_calls", message: {
          role: "assistant", content: nil,
          tool_calls: [ { id: "call_1", type: "function", function: { name: "issue_refund", arguments: "{}" } } ]
        } } ],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      }.to_json
    )

    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM", model: "gpt-4o-mini",
      messages: [ { role: "user", content: "Refund order 7" } ],
      tools: [ REFUND_TOOL ],
      tools_function: ASK
    )

    error = assert_raises(ActiveAgent::InputRequest::UnsupportedProviderError) { provider.prompt }
    assert_match(/RubyLLM cannot pause/, error.message)
    assert_requested stub, times: 1
  ensure
    RubyLLM.config.openai_api_key = original_key
    RubyLLM.config.openai_protocol = original_protocol if RubyLLM.config.respond_to?(:openai_protocol)
  end
end
