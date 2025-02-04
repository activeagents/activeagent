require "minitest/autorun"
require "mocha/minitest"
require_relative "../lib/active_agent/generation_provider/open_ai_provider"

class OpenAIProviderTest < Minitest::Test
  def setup
    @config = {"api_key" => "test_api_key", "model" => "gpt-4o-mini"}
    @provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(@config)
    @prompt = mock("prompt")
    @prompt.stubs(:config).returns({})
    @prompt.stubs(:messages).returns([])
  end

  def test_initialize
    assert_equal "test_api_key", @provider.instance_variable_get(:@api_key)
    assert_equal "gpt-4o-mini", @provider.instance_variable_get(:@model_name)
  end

  def test_generate_success
    @prompt.stubs(:parameters).returns({prompt: "Hello"})
    @provider.stubs(:prompt_parameters).returns({prompt: "Hello"})
    response = {"choices" => [{"message" => {"content" => "Hi", "role" => "assistant"}}]}
    @provider.instance_variable_get(:@client).stubs(:chat).returns(response)

    result = @provider.generate(@prompt)
    assert_equal "Hi", result.message.content
  end

  def test_generate_error
    @prompt.stubs(:parameters).returns({prompt: "Hello"})
    @provider.stubs(:prompt_parameters).returns({prompt: "Hello"})
    @provider.instance_variable_get(:@client).stubs(:chat).raises(StandardError.new("API error"))

    assert_raises(ActiveAgent::GenerationProvider::GenerationProviderError) do
      @provider.generate(@prompt)
    end
  end

  def test_handle_response
    response = {"choices" => [{"message" => {"content" => "Hi", "role" => "assistant"}}]}
    result = @provider.send(:handle_response, response)
    assert_equal "Hi", result.message.content
    assert_equal "assistant", result.message.role
  end
end

def test_provider_stream
  chunk = {"choices" => [{"delta" => {"content" => "new content"}, "index" => 0}]}
  message = mock("message")
  message.stubs(:response_number).returns(0)
  message.stubs(:content).returns("existing content")
  message.expects(:update).with(content: "existing contentnew content")
  @prompt.stubs(:messages).returns([message])
  agent_stream = mock("agent_stream")
  agent_stream.expects(:call).with(message)
  @prompt.stubs(:config).returns({stream: agent_stream})

  stream_proc = @provider.send(:provider_stream)
  stream_proc.call(chunk, 1024)
end

def test_prompt_parameters
  @prompt.stubs(:messages).returns(["message1", "message2"])
  @prompt.stubs(:actions).returns(["action1", "action2"])
  @config["temperature"] = 0.9

  expected_parameters = {
    messages: ["message1", "message2"],
    temperature: 0.9,
    tools: ["action1", "action2"]
  }

  assert_equal expected_parameters, @provider.send(:prompt_parameters)
end

def test_handle_response_with_tool_calls
  tool_calls = [{"function" => {"name" => "action1", "arguments" => '{"param1": "value1"}'}}]
  response = {"choices" => [{"message" => {"content" => "Hi", "role" => "assistant", "finish_reason" => "tool_calls", "tool_calls" => tool_calls}}]}
  result = @provider.send(:handle_response, response)

  assert_equal "Hi", result.message.content
  assert_equal "assistant", result.message.role
  assert result.message.action_requested
  assert_equal 1, result.message.requested_actions.size
  assert_equal "action1", result.message.requested_actions.first.name
  assert_equal({param1: "value1"}, result.message.requested_actions.first.params)
end

def test_handle_response_without_tool_calls
  response = {"choices" => [{"message" => {"content" => "Hi", "role" => "assistant", "finish_reason" => "stop"}}]}
  result = @provider.send(:handle_response, response)

  assert_equal "Hi", result.message.content
  assert_equal "assistant", result.message.role
  refute result.message.action_requested
  assert_empty result.message.requested_actions
end
