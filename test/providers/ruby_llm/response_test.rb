# frozen_string_literal: true

require "test_helper"
require "ruby_llm"
require "active_agent/providers/ruby_llm_provider"
require_relative "ruby_llm_helper"

# What RubyLLMProvider makes of the response ruby_llm returns: the usage it
# reports and why the response ended. Runs on ruby_llm 1.16 and 2.x, which
# count tokens under different names and only 2.x says why a response ended.
class RubyLLMResponseTest < ActiveSupport::TestCase
  include WebMock::API
  include RubyLLMHelper

  OPENAI_ENDPOINT = "https://api.openai.com/v1/chat/completions"
  ANTHROPIC_ENDPOINT = "https://api.anthropic.com/v1/messages"

  setup do
    @original_config = RubyLLM.config.openai_api_key, RubyLLM.config.anthropic_api_key
    if RubyLLM.config.respond_to?(:openai_protocol)
      @original_openai_protocol = RubyLLM.config.openai_protocol
      RubyLLM.config.openai_protocol = :chat_completions
    end
    RubyLLM.configure do |config|
      config.openai_api_key = "test-openai-key"
      config.anthropic_api_key = "test-anthropic-key"
    end
  end

  teardown do
    RubyLLM.config.openai_api_key, RubyLLM.config.anthropic_api_key = @original_config
    RubyLLM.config.openai_protocol = @original_openai_protocol if RubyLLM.config.respond_to?(:openai_protocol)
  end

  # --- Usage ---

  test "reports the cache and thinking tokens ruby_llm counted" do
    message = ::RubyLLM::Message.new(
      role: :assistant,
      content: "Cached.",
      **ruby_llm_token_attributes(input: 10, output: 5, cache_read: 30, cache_write: 4, thinking: 2)
    )

    usage = prompt_answered_by(message).usage

    assert_equal 10, usage.input_tokens
    assert_equal 5, usage.output_tokens
    assert_equal 30, usage.cached_tokens
    assert_equal 4, usage.cache_creation_tokens
    assert_equal 2, usage.reasoning_tokens
  end

  # ruby_llm 1.16 has no token counts at all on such a message (its tokens is
  # nil), as when a server leaves usage out of its response.
  test "reports no usage when ruby_llm counted no tokens" do
    message = ::RubyLLM::Message.new(role: :assistant, content: "No counts.")

    response = prompt_answered_by(message)

    assert_equal "No counts.", response.messages.last.content
    assert_nil response.usage
  end

  test "reports a zero for whichever of input and output tokens ruby_llm left out" do
    message = ::RubyLLM::Message.new(role: :assistant, content: "Input only.", **ruby_llm_token_attributes(input: 7))

    usage = prompt_answered_by(message).usage

    assert_equal 7, usage.input_tokens
    assert_equal 0, usage.output_tokens
    assert_equal 7, usage.total_tokens
  end

  %i[cache_read cache_write thinking].each do |count|
    test "preserves usage when only #{count} tokens were reported" do
      message = ::RubyLLM::Message.new(role: :assistant, content: "Partial counts.",
        **ruby_llm_token_attributes(**{ count => 3 }))

      usage = prompt_answered_by(message).usage

      assert_not_nil usage
      field = { cache_read: :cached_tokens, cache_write: :cache_creation_tokens, thinking: :reasoning_tokens }.fetch(count)
      assert_equal 3, usage.public_send(field)
      assert_equal 0, usage.input_tokens
      assert_equal 0, usage.output_tokens
    end
  end

  # ruby_llm's OpenAI parser reports a cache write of zero for a response that
  # carries no usage, so a zero there is not something the server counted.
  test "reports no usage when the only count is a zero cache or thinking count" do
    %i[cache_read cache_write thinking].each do |count|
      message = ::RubyLLM::Message.new(role: :assistant, content: "Zero.", **ruby_llm_token_attributes(**{ count => 0 }))

      assert_nil prompt_answered_by(message).usage, "for #{count}"
    end
  end

  test "reports no usage when OpenAI leaves usage out of its response" do
    stub_response(OPENAI_ENDPOINT, openai_response(usage: nil))

    response = wire_prompt("gpt-4o-mini")

    assert_equal "Hi.", response.messages.last.content
    assert_nil response.usage
  end

  test "preserves explicitly reported zero token counts" do
    message = ::RubyLLM::Message.new(role: :assistant, content: "Empty usage.",
      **ruby_llm_token_attributes(input: 0, output: 0, cache_read: 0, cache_write: 0, thinking: 0))

    usage = prompt_answered_by(message).usage

    assert_not_nil usage
    assert_equal 0, usage.total_tokens
    assert_equal 0, usage.cached_tokens
    assert_equal 0, usage.cache_creation_tokens
    assert_equal 0, usage.reasoning_tokens
  end

  # The usage of every turn is added up, so one turn missing a count must not
  # leave a nil behind for the next addition.
  test "adds up the usage of a tool loop whose first turn counted only input tokens" do
    call = ::RubyLLM::ToolCall.new(id: "call_1", name: "get_weather", arguments: "{}")
    asking = ::RubyLLM::Message.new(role: :assistant, content: "", tool_calls: { "call_1" => call },
                                    **ruby_llm_token_attributes(input: 7))
    answering = ::RubyLLM::Message.new(role: :assistant, content: "Sunny.",
                                       **ruby_llm_token_attributes(input: 11, output: 3))

    usage = prompt_answered_by(asking, answering, tools: true).usage

    assert_equal 18, usage.input_tokens
    assert_equal 3, usage.output_tokens
  end

  test "reports the tokens OpenAI counted, its cached tokens apart from the input" do
    stub_response(OPENAI_ENDPOINT, openai_response(usage: { prompt_tokens: 12, completion_tokens: 4, total_tokens: 16,
                                                            prompt_tokens_details: { cached_tokens: 5 } }))

    usage = wire_prompt("gpt-4o-mini").usage

    assert_equal 7, usage.input_tokens
    assert_equal 4, usage.output_tokens
    assert_equal 5, usage.cached_tokens
  end

  test "reports the tokens Anthropic counted, cache reads and writes included" do
    stub_response(ANTHROPIC_ENDPOINT, anthropic_response(
      usage: { input_tokens: 12, output_tokens: 4, cache_read_input_tokens: 5, cache_creation_input_tokens: 2 }
    ))

    usage = wire_prompt("claude-haiku-4-5").usage

    assert_equal 12, usage.input_tokens
    assert_equal 4, usage.output_tokens
    assert_equal 5, usage.cached_tokens
    assert_equal 2, usage.cache_creation_tokens
  end

  # --- Stop reason ---

  # ruby_llm 2.0 normalizes a response's finish reason to :stop, :max_tokens,
  # :tool_calls or :content_filter, and passes any other through as the
  # provider spelled it; before it there is none to read.
  {
    max_tokens: "max_tokens",
    content_filter: "content_filter",
    stop: "end_turn",
    pause_turn: "pause_turn"
  }.each do |finish_reason, stop_reason|
    test "the stop_reason of a response that finished with #{finish_reason} is #{stop_reason}" do
      skip_unless_ruby_llm_2!("Message#finish_reason")
      message = ::RubyLLM::Message.new(role: :assistant, content: "Cut.", finish_reason: finish_reason)

      assert_equal stop_reason, prompt_answered_by(message).raw_response[:stop_reason]
    end
  end

  # A response that asks for tools is tool_use however the API spells it:
  # OpenAI's Responses API ends one with :stop.
  [ :tool_calls, :stop ].each do |finish_reason|
    test "the stop_reason of a tool call response that finished with #{finish_reason} is tool_use" do
      skip_unless_ruby_llm_2!("Message#finish_reason")

      assert_equal "tool_use", stop_reason_of(tool_call_message(finish_reason: finish_reason))
    end
  end

  test "the stop_reason of a response cut off while calling a tool is max_tokens" do
    skip_unless_ruby_llm_2!("Message#finish_reason")

    assert_equal "max_tokens", stop_reason_of(tool_call_message(finish_reason: :max_tokens))
  end

  test "the stop_reason is inferred from the tool calls when the response has no finish reason" do
    plain = ::RubyLLM::Message.new(role: :assistant, content: "Done.")

    assert_equal "end_turn", stop_reason_of(plain)
    assert_equal "tool_use", stop_reason_of(tool_call_message)
  end

  test "reports a response OpenAI cut off at the limit as max_tokens" do
    skip_unless_ruby_llm_2!("Message#finish_reason")
    stub_response(OPENAI_ENDPOINT, openai_response(finish_reason: "length"))

    assert_equal "max_tokens", wire_prompt("gpt-4o-mini").raw_response[:stop_reason]
  end

  test "reports a response Anthropic cut off at the limit as max_tokens" do
    skip_unless_ruby_llm_2!("Message#finish_reason")
    stub_response(ANTHROPIC_ENDPOINT, anthropic_response(stop_reason: "max_tokens"))

    assert_equal "max_tokens", wire_prompt("claude-haiku-4-5").raw_response[:stop_reason]
  end

  private

  # Prompts through a provider whose ruby_llm answers with the messages in turn.
  def prompt_answered_by(*messages, tools: false)
    options = tools ? { tools: [ tool_definition ], tools_function: ->(_name, **_arguments) { { temp: 72 } } } : {}

    with_ruby_llm_provider(ScriptedProvider.new(*messages)) do
      ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM", model: "gpt-4o-mini", messages: [ { role: "user", content: "hello" } ], **options
      ).prompt
    end
  end

  def stop_reason_of(message)
    provider = ActiveAgent::Providers::RubyLLMProvider.new(service: "RubyLLM", model: "gpt-4o-mini")
    provider.send(:normalize_ruby_llm_response, message, "gpt-4o-mini")[:stop_reason]
  end

  def tool_call_message(finish_reason: nil)
    call = ::RubyLLM::ToolCall.new(id: "call_1", name: "get_weather", arguments: "{}")
    ::RubyLLM::Message.new(role: :assistant, content: "", tool_calls: { "call_1" => call }, finish_reason: finish_reason)
  end

  def tool_definition
    {
      type: "function",
      function: { name: "get_weather", description: "Weather", parameters: { type: "object", properties: {} } }
    }
  end

  def wire_prompt(model)
    ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM", model: model, messages: [ { role: "user", content: "Say hello" } ]
    ).prompt
  end

  def stub_response(endpoint, body)
    stub_request(:post, endpoint).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  def openai_response(finish_reason: "stop", usage: { prompt_tokens: 12, completion_tokens: 4, total_tokens: 16 })
    {
      id: "chatcmpl-response-test",
      object: "chat.completion",
      model: "gpt-4o-mini",
      choices: [ { index: 0, message: { role: "assistant", content: "Hi." }, finish_reason: finish_reason } ],
      usage: usage
    }
  end

  def anthropic_response(stop_reason: "end_turn", usage: { input_tokens: 12, output_tokens: 4 })
    {
      id: "msg_response_test",
      type: "message",
      role: "assistant",
      model: "claude-haiku-4-5",
      content: [ { type: "text", text: "Hi." } ],
      stop_reason: stop_reason,
      usage: usage
    }
  end
end
