require "test_helper"

class OllamaAgentTest < ActiveSupport::TestCase
  test "it renders a prompt_context and generates a response" do
    VCR.use_cassette("ollama_prompt_context_response") do
      message = "Show me a cat"
      prompt = OllamaAgent.with(message: message).prompt_context
      response = prompt.generate_now

      assert_equal message, OllamaAgent.with(message: message).prompt_context.message.content
      assert_equal 3, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal message, response.prompt.messages[1].content
      assert_equal :assistant, response.prompt.messages[2].role
    end
  end

  test "it uses the correct model" do
    prompt = OllamaAgent.with(message: "Test").prompt_context
    assert_equal "gemma3:latest", prompt.options[:model]
  end

  test "it sets the correct system instructions" do
    prompt = OllamaAgent.with(message: "Test").prompt_context
    system_message = prompt.messages.find { |m| m.role == :system }
    assert_equal "You're a basic Ollama agent.", system_message.content
  end
end
