require "minitest/autorun"
require "mocha/minitest"
require_relative "../lib/active_agent/generation_provider/open_ai_provider"
require_relative "../lib/active_agent/action_prompt"
require_relative "../lib/active_agent/generation_provider/base"

class OpenAIProviderTest < Minitest::Test
  def setup
    @config = {"api_key" => "test_api_key", "model" => "gpt-4o-mini"}
    @provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(@config)
    @prompt = mock("prompt")
    @prompt.stubs(:config).returns({})
    @prompt.stubs(:messages).returns([])
    @prompt.stubs(:parameters).returns({prompt: "Hello"})
    @prompt.stubs(:options).returns({})
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

    assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
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
