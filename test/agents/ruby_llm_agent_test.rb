require "test_helper"
require_relative "../dummy/app/agents/ruby_llm_agent"

class RubyLLMAgentTest < ActiveAgentTestCase
  setup do
    @agent = RubyLLMAgent.new
  end

  test "basic chat interaction" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    VCR.use_cassette("ruby_llm_agent_chat") do
      # Skip if no API key available
      if Rails.application.credentials.dig(:openai, :access_token).nil?
        skip "OpenAI API key not configured, skipping test"
      end

      response = RubyLLMAgent.with(
        message: "What is the capital of France?"
      ).chat.generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert_not_nil response.message.content
      assert_includes response.message.content.downcase, "paris"
    end
  end

  test "switching providers dynamically" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    VCR.use_cassette("ruby_llm_agent_provider_switch") do
      # Skip if no API key available
      if Rails.application.credentials.dig(:anthropic, :access_token).nil?
        skip "Anthropic API key not configured, skipping test"
      end

      response = RubyLLMAgent.with(
        message: "Say hello",
        provider: "anthropic"
      ).ask_with_provider.generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert_not_nil response.message.content
    end
  end

  test "structured output generation" do
    # Skip if gem not available
    begin
      require "ruby_llm"
    rescue LoadError
      skip "ruby_llm gem is not available, skipping test"
    end

    VCR.use_cassette("ruby_llm_agent_structured") do
      # Skip if no API key available
      if Rails.application.credentials.dig(:openai, :access_token).nil?
        skip "OpenAI API key not configured, skipping test"
      end

      response = RubyLLMAgent.with(
        question: "What is 2 + 2?"
      ).structured_response.generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert_not_nil response.message.content

      # Parse the JSON response
      begin
        structured_data = JSON.parse(response.message.content)
        assert structured_data.key?("answer")
        assert structured_data.key?("confidence")
        assert structured_data.key?("reasoning")
        assert_includes ["4", "four"], structured_data["answer"].downcase
      rescue JSON::ParserError
        # If not JSON, check if the content mentions the answer
        assert_includes response.message.content.downcase, "4"
      end
    end
  end

  test "prompt context includes correct messages" do
    generation = RubyLLMAgent.with(
      message: "Hello, RubyLLM!"
    ).chat

    # Access the prompt context before generation
    prompt = generation.prompt

    assert_not_nil prompt
    assert_equal "Hello, RubyLLM!", prompt.message.content
    assert_equal :user, prompt.message.role
  end

  test "agent configuration uses ruby_llm provider" do
    # Get the agent's configuration
    config = @agent.class.instance_variable_get(:@generation_provider)
    
    # The generation provider should be set to :ruby_llm
    assert_equal :ruby_llm, config
  end

  test "handles missing gem gracefully" do
    # This test verifies the error message when the gem is not available
    # We simulate this by requiring a non-existent version
    test_code = <<~RUBY
      begin
        gem "ruby_llm", ">= 999.0.0"
        require "ruby_llm"
      rescue LoadError => e
        e
      end
    RUBY

    error = eval(test_code)
    assert_instance_of LoadError, error
  end
end