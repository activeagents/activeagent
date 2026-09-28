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

  # --- Structured output ---

  GREETING_SCHEMA = {
    type: "object",
    properties: { text: { type: "string" } },
    required: [ "text" ],
    additionalProperties: false
  }.freeze

  test "sends OpenAI the name, schema and strict flag of a json_schema response_format" do
    bodies = stub_responses(OPENAI_ENDPOINT, openai_response(content: '{"text":"hello"}'))

    greeting_provider(
      model: "gpt-4o-mini",
      response_format: { type: "json_schema", json_schema: { name: "greeting", strict: false, schema: GREETING_SCHEMA } }
    ).prompt

    assert_equal(
      { "type" => "json_schema",
        "json_schema" => { "name" => "greeting", "schema" => GREETING_SCHEMA.deep_stringify_keys, "strict" => false } },
      bodies.last["response_format"]
    )
  end

  test "names the schema response and makes it strict when the response_format leaves them out" do
    bodies = stub_responses(OPENAI_ENDPOINT, openai_response(content: '{"text":"hello"}'))

    greeting_provider(
      model: "gpt-4o-mini",
      response_format: { type: "json_schema", json_schema: { schema: GREETING_SCHEMA } }
    ).prompt

    assert_equal "response", bodies.last.dig("response_format", "json_schema", "name")
    assert_equal true, bodies.last.dig("response_format", "json_schema", "strict")
  end

  test "sends Anthropic the schema of a json_schema response_format" do
    bodies = stub_responses(ANTHROPIC_ENDPOINT, anthropic_response(content: [ { type: "text", text: '{"text":"hello"}' } ]))

    greeting_provider(
      model: "claude-haiku-4-5",
      response_format: { type: "json_schema", json_schema: { name: "greeting", strict: true, schema: GREETING_SCHEMA } }
    ).prompt

    assert_equal({ "format" => { "type" => "json_schema", "schema" => GREETING_SCHEMA.deep_stringify_keys } },
                 bodies.last["output_config"])
  end

  # The agent turns response_format's json_schema into string keys before
  # the provider sees it.
  test "sends the schema an agent's prompt declares" do
    bodies = stub_responses(OPENAI_ENDPOINT, openai_response(content: '{"text":"hello"}'))
    agent_class = Class.new(ApplicationAgent) do
      def self.name = "WireFormatGreetingAgent"
      generate_with :ruby_llm, model: "gpt-4o-mini"

      def greet
        prompt(message: "Say hello",
               response_format: { type: "json_schema", json_schema: { name: "greeting", schema: GREETING_SCHEMA } })
      end
    end

    agent_class.greet.generate_now

    assert_equal "greeting", bodies.last.dig("response_format", "json_schema", "name")
    assert_equal GREETING_SCHEMA.deep_stringify_keys, bodies.last.dig("response_format", "json_schema", "schema")
  end

  test "asks for plain text when the response_format is text" do
    [ { type: "text" }, :text ].each do |response_format|
      bodies = stub_responses(OPENAI_ENDPOINT, openai_response(content: "hello"))

      greeting_provider(model: "gpt-4o-mini", response_format: response_format).prompt

      assert_not bodies.last.key?("response_format"), "for #{response_format.inspect}"
    end
  end

  test "refuses a json_object response_format, which ruby_llm has no mode for" do
    stub = stub_request(:post, OPENAI_ENDPOINT)

    error = assert_raises(ArgumentError) do
      greeting_provider(model: "gpt-4o-mini", response_format: { type: "json_object" }).prompt
    end

    assert_match "json_object", error.message
    assert_not_requested stub
  end

  test "refuses a json_schema response_format without a schema" do
    stub = stub_request(:post, OPENAI_ENDPOINT)

    error = assert_raises(ArgumentError) do
      greeting_provider(model: "gpt-4o-mini", response_format: { type: "json_schema" }).prompt
    end

    assert_match "schema", error.message
    assert_not_requested stub
  end

  private

  def greeting_provider(model:, response_format:)
    ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: model,
      messages: [ { role: "user", content: "Say hello" } ],
      response_format: response_format
    )
  end

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
