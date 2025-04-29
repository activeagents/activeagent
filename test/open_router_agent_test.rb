require "test_helper"

class OpenRouterAgentTest < ActiveSupport::TestCase
  test "it renders a text_prompt and generates a response" do
    VCR.use_cassette("open_router_text_prompt_response") do
      message = "Show me a cat"
      prompt = OpenRouterAgent.with(message: message).text_prompt
      response = prompt.generate_now

      assert_equal message, OpenRouterAgent.with(message: message).text_prompt.message.content
      assert_equal 3, response.prompt.messages.size
      assert_equal :system, response.prompt.messages[0].role
      assert_equal :user, response.prompt.messages[1].role
      assert_equal message, response.prompt.messages[1].content
      assert_equal :assistant, response.prompt.messages[2].role
    end
  end

  test "it uses the correct model" do
    prompt = OpenRouterAgent.new.text_prompt
    assert_equal "qwen/qwen3-30b-a3b:free", prompt.options[:model]
  end

  test "it sets the correct system instructions" do
    prompt = OpenRouterAgent.new.text_prompt
    system_message = prompt.messages.find { |m| m.role == :system }
    assert_equal "You're a basic OpenAI agent.", system_message.content
  end
end
