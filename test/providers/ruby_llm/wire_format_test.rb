# frozen_string_literal: true

require "test_helper"
require "ruby_llm"
require "active_agent/providers/ruby_llm_provider"

# What RubyLLMProvider's requests look like once ruby_llm renders them for
# the provider's API. Everything below the HTTP call is real -- model
# resolution, ruby_llm's payload rendering and response parsing -- and each
# test asserts on the request bodies the provider API receives.
class RubyLLMWireFormatTest < ActiveSupport::TestCase
  include WebMock::API

  OPENAI_ENDPOINT = "https://api.openai.com/v1/chat/completions"
  ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"

  WEATHER_TOOL = {
    type: "function",
    function: {
      name: "get_weather",
      description: "Current weather for a city",
      parameters: {
        type: "object",
        properties: { city: { type: "string" } },
        required: [ "city" ]
      }
    }
  }.freeze

  setup do
    @original_keys = RubyLLM.config.openai_api_key, RubyLLM.config.anthropic_api_key
    RubyLLM.configure do |config|
      config.openai_api_key = "test-openai-key"
      config.anthropic_api_key = "test-anthropic-key"
    end
  end

  teardown do
    RubyLLM.config.openai_api_key, RubyLLM.config.anthropic_api_key = @original_keys
  end

  # --- Tool calls ---

  test "sends OpenAI the arguments of the tool call it made, as the JSON it sent" do
    bodies = stub_responses(OPENAI_ENDPOINT,
      openai_response(tool_calls: [
        { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Boston"}' } }
      ]),
      openai_response(content: "It's 72F in Boston."))

    response = weather_provider(model: "gpt-4o-mini").prompt

    assert_equal "It's 72F in Boston.", response.messages.last.content
    replayed = bodies.last["messages"].find { |message| message["tool_calls"] }
    assert_equal '{"city":"Boston"}', replayed.dig("tool_calls", 0, "function", "arguments")
  end

  test "sends Anthropic the input of the tool call it made, as an object" do
    bodies = stub_responses(ANTHROPIC_ENDPOINT,
      anthropic_response(content: [ { type: "tool_use", id: "toolu_1", name: "get_weather", input: { city: "Boston" } } ],
                         stop_reason: "tool_use"),
      anthropic_response(content: [ { type: "text", text: "It's 72F in Boston." } ]))

    response = weather_provider(model: "claude-haiku-4-5").prompt

    assert_equal "It's 72F in Boston.", response.messages.last.content
    tool_use = bodies.last["messages"].flat_map { |message| Array(message["content"]) }
                     .find { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
    assert_equal({ "city" => "Boston" }, tool_use["input"])
  end

  test "replays a stored conversation's tool call arguments to Anthropic as an object" do
    bodies = stub_responses(ANTHROPIC_ENDPOINT, anthropic_response(content: [ { type: "text", text: "Sunny." } ]))

    ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "claude-haiku-4-5",
      messages: [
        { role: "user", content: "Weather in Boston?" },
        { role: "assistant", content: "", tool_calls: [
          { id: "toolu_1", type: "function", function: { name: "get_weather", arguments: '{"city":"Boston"}' } }
        ] },
        { role: "tool", tool_call_id: "toolu_1", content: '{"temp":72}' },
        { role: "user", content: "And tomorrow?" }
      ]
    ).prompt

    tool_use = bodies.last["messages"].flat_map { |message| Array(message["content"]) }
                     .find { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
    assert_equal({ "city" => "Boston" }, tool_use["input"])
  end

  private

  def weather_provider(model:)
    ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: model,
      messages: [ { role: "user", content: "Weather in Boston?" } ],
      tools: [ WEATHER_TOOL ],
      tools_function: ->(_name, **_arguments) { { temp: 72 } }
    )
  end

  # Answers successive requests to endpoint with responses, in order, and
  # returns the list the parsed request bodies are collected into.
  def stub_responses(endpoint, *responses)
    bodies = []
    queue = responses.dup

    stub_request(:post, endpoint).to_return do |request|
      bodies << JSON.parse(request.body)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: queue.shift.to_json }
    end

    bodies
  end

  def openai_response(content: nil, tool_calls: nil)
    message = { role: "assistant", content: content }
    message[:tool_calls] = tool_calls if tool_calls

    {
      id: "chatcmpl-wire-format",
      object: "chat.completion",
      model: "gpt-4o-mini",
      choices: [ { index: 0, message: message, finish_reason: tool_calls ? "tool_calls" : "stop" } ],
      usage: { prompt_tokens: 12, completion_tokens: 4, total_tokens: 16 }
    }
  end

  def anthropic_response(content:, stop_reason: "end_turn")
    {
      id: "msg_wire_format",
      type: "message",
      role: "assistant",
      model: "claude-haiku-4-5",
      content: content,
      stop_reason: stop_reason,
      usage: { input_tokens: 12, output_tokens: 4 }
    }
  end
end
