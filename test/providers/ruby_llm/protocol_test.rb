# frozen_string_literal: true

require "test_helper"
require "ruby_llm"
require "active_agent/providers/ruby_llm_provider"
require_relative "ruby_llm_helper"

# The protocol option, which pins the wire protocol RubyLLM uses for a request
# (RubyLLM's protocol:). ruby_llm 2.x sends OpenAI chat to the Responses API
# and keeps Chat Completions behind it; 1.16 only has Chat Completions.
class RubyLLMProtocolTest < ActiveSupport::TestCase
  include WebMock::API
  include RubyLLMHelper

  CHAT_COMPLETIONS = "https://api.openai.com/v1/chat/completions"
  RESPONSES = "https://api.openai.com/v1/responses"

  setup do
    @original_api_key = RubyLLM.config.openai_api_key
    @original_openai_protocol = RubyLLM.config.openai_protocol if RubyLLM.config.respond_to?(:openai_protocol)
    RubyLLM.config.openai_api_key = "test-openai-key"
  end

  teardown do
    RubyLLM.config.openai_api_key = @original_api_key
    RubyLLM.config.openai_protocol = @original_openai_protocol if RubyLLM.config.respond_to?(:openai_protocol)
  end

  # --- What complete is asked for ---

  test "passes the protocol on to ruby_llm" do
    skip_unless_ruby_llm_2!("the protocol option")

    [ :chat_completions, "chat_completions" ].each do |protocol|
      ruby_llm = ScriptedProvider.new(reply)

      prompt(ruby_llm, protocol: protocol)

      assert_equal :chat_completions, ruby_llm.requests.last[:protocol], "for #{protocol.inspect}"
    end
  end

  test "leaves the protocol to ruby_llm when the option is not set" do
    ruby_llm = ScriptedProvider.new(reply)

    prompt(ruby_llm)

    assert_not ruby_llm.requests.last.key?(:protocol)
  end

  test "refuses the protocol option before sending anything when ruby_llm has no protocols" do
    skip "protocols exist in ruby_llm 2.x, #{::RubyLLM::VERSION} is loaded" if ruby_llm_2?
    ruby_llm = ScriptedProvider.new(reply)

    error = assert_raises(ArgumentError) { prompt(ruby_llm, protocol: :responses) }

    assert_includes error.message, "ruby_llm 2.0"
    assert_includes error.message, ::RubyLLM::VERSION
    assert_empty ruby_llm.requests
  end

  test "reaches the provider options from generate_with" do
    agent_class = Class.new(ApplicationAgent) do
      def self.name = "ProtocolProbeAgent"
      generate_with :ruby_llm, model: "gpt-4o-mini", protocol: :chat_completions

      def ping
        prompt(message: "hello")
      end
    end

    agent = agent_class.new
    agent.params = {}
    agent.process(:ping)
    parameters = agent.send(:prepare_prompt_parameters)

    provider = agent.prompt_provider_klass.new(**parameters)
    assert_equal "chat_completions", provider.options.protocol
  end

  # --- Where the request goes ---

  test "sends OpenAI chat to the Responses API unless told otherwise" do
    skip_unless_ruby_llm_2!("the Responses API")
    RubyLLM.config.openai_protocol = nil
    responses = stub_json(RESPONSES, responses_body)
    chat_completions = stub_json(CHAT_COMPLETIONS, chat_completions_body)

    wire_prompt

    assert_requested responses
    assert_not_requested chat_completions
  end

  test "pins OpenAI chat to Chat Completions over ruby_llm's own setting" do
    skip_unless_ruby_llm_2!("the protocol option")
    RubyLLM.config.openai_protocol = :responses
    responses = stub_json(RESPONSES, responses_body)
    chat_completions = stub_json(CHAT_COMPLETIONS, chat_completions_body)

    wire_prompt(protocol: :chat_completions)

    assert_requested chat_completions
    assert_not_requested responses
  end

  test "pins OpenAI chat to the Responses API over ruby_llm's own setting" do
    skip_unless_ruby_llm_2!("the protocol option")
    RubyLLM.config.openai_protocol = :chat_completions
    responses = stub_json(RESPONSES, responses_body)
    chat_completions = stub_json(CHAT_COMPLETIONS, chat_completions_body)

    wire_prompt(protocol: :responses)

    assert_requested responses
    assert_not_requested chat_completions
  end

  test "uses ruby_llm's configured protocol when the agent has no override" do
    skip_unless_ruby_llm_2!("the protocol option")
    RubyLLM.config.openai_protocol = :chat_completions
    responses = stub_json(RESPONSES, responses_body)
    chat_completions = stub_json(CHAT_COMPLETIONS, chat_completions_body)

    wire_prompt

    assert_requested chat_completions
    assert_not_requested responses
  end

  test "refuses an unknown protocol before making an HTTP request" do
    skip_unless_ruby_llm_2!("the protocol option")
    responses = stub_json(RESPONSES, responses_body)
    chat_completions = stub_json(CHAT_COMPLETIONS, chat_completions_body)

    error = assert_raises(::RubyLLM::Error) { wire_prompt(protocol: :unsupported) }

    assert_includes error.message, "unsupported"
    assert_includes error.message, "Available:"
    assert_not_requested responses
    assert_not_requested chat_completions
  end

  test "pins the protocol on every turn of a streamed tool loop" do
    skip_unless_ruby_llm_2!("the protocol option")
    call = ::RubyLLM::ToolCall.new(id: "call_1", name: "get_weather", arguments: "{}")
    ruby_llm = ScriptedProvider.new(
      [ ::RubyLLM::Chunk.new(role: :assistant, content: nil, tool_calls: { 0 => call }, finish_reason: :stop) ],
      [ ::RubyLLM::Chunk.new(role: :assistant, content: "Done.", finish_reason: :stop) ]
    )

    response = prompt(ruby_llm, protocol: :chat_completions, stream: true, stream_broadcaster: ->(*) { },
      tools: [ { name: "get_weather", parameters: { type: "object", properties: {} } } ],
      tools_function: ->(*) { {} })

    assert_equal [ :chat_completions, :chat_completions ], ruby_llm.requests.map { |request| request[:protocol] }
    assert_equal "Done.", response.message.content
    assert_equal "end_turn", response.finish_reason
  end

  test "a prompt protocol option does not change embedding routing" do
    endpoint = "https://api.openai.com/v1/embeddings"
    embeddings = stub_json(endpoint, { model: "text-embedding-3-small",
      data: [ { index: 0, embedding: [ 0.1, 0.2 ] } ], usage: { prompt_tokens: 2, total_tokens: 2 } })

    response = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM", model: "text-embedding-3-small", protocol: :chat_completions, input: "hello", dimensions: 2
    ).embed

    assert_equal [ 0.1, 0.2 ], response.data.first[:embedding]
    assert_requested embeddings
  end

  private

  def reply
    ::RubyLLM::Message.new(role: :assistant, content: "Hi.")
  end

  def prompt(ruby_llm, **options)
    with_ruby_llm_provider(ruby_llm) do
      ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM", model: "gpt-4o-mini", messages: [ { role: "user", content: "hello" } ], **options
      ).prompt
    end
  end

  def wire_prompt(**options)
    ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM", model: "gpt-4o-mini", messages: [ { role: "user", content: "hello" } ], **options
    ).prompt
  end

  def stub_json(endpoint, body)
    stub_request(:post, endpoint).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end

  def chat_completions_body
    {
      id: "chatcmpl-protocol", object: "chat.completion", model: "gpt-4o-mini",
      choices: [ { index: 0, message: { role: "assistant", content: "Hi." }, finish_reason: "stop" } ],
      usage: { prompt_tokens: 3, completion_tokens: 1, total_tokens: 4 }
    }
  end

  def responses_body
    {
      id: "resp_protocol", object: "response", model: "gpt-4o-mini", status: "completed",
      output: [ { type: "message", id: "msg_protocol", role: "assistant", content: [ { type: "output_text", text: "Hi." } ] } ],
      usage: { input_tokens: 3, output_tokens: 1, total_tokens: 4 }
    }
  end
end
