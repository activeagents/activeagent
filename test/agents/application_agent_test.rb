# test/application_agent_test.rb - additional test for embed functionality

require "test_helper"

class ApplicationAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with an 'Test' message" do
    assert_equal "Test", ApplicationAgent.with(message: "Test").prompt_context.message.content
  end

  test "it renders a prompt with an plain text message" do
    assert_equal "Test Application Agent", ApplicationAgent.with(message: "Test Application Agent").prompt_context.message.content
  end

  test "it renders a prompt with an plain text message and generates a response" do
    VCR.use_cassette("application_agent_prompt_context_message_generation") do
      test_response_message_content = "Hello! How can I assist you today with your test application?"
      # region application_agent_prompt_context_message_generation
      message = "Test Application Agent"
      response = ApplicationAgent.with(message: message).prompt_context.generate_now
      # endregion application_agent_prompt_context_message_generation
      assert_equal test_response_message_content, response.message.content
    end
  end

  test "it renders a prompt with an plain text message with previous messages and generates a response" do
    VCR.use_cassette("application_agent_loaded_context_message_generation") do
      test_response_message_content = "Sure! What specific issues are you experiencing with your account?"
      # region application_agent_loaded_context_message_generation
      message = "I need help with my account"
      previous_context = ActiveAgent::ActionPrompt::Prompt.new(
        messages: [ { content: "Hello, how can I assist you today?", role: :assistant } ],
        instructions: "You're an application agent"
      )
      response = ApplicationAgent.with(message: message, messages: previous_context.messages).prompt_context.generate_now
      # endregion application_agent_loaded_context_message_generation
      assert_equal test_response_message_content, response.message.content
    end
  end

  test "embed generates vector for message content" do
    VCR.use_cassette("application_agent_message_embedding") do
      message = ActiveAgent::ActionPrompt::Message.new(content: "Test content for embedding")
      response = message.embed

      assert_not_nil response
      assert_equal message, response
      # Assuming your provider returns a vector when embed is called
      assert_not_nil response.content
    end
  end

  test "embed can be called directly on an agent instance" do
    VCR.use_cassette("application_agent_embeddings") do
      agent = ApplicationAgent.new
      agent.context = ActiveAgent::ActionPrompt::Prompt.new(
        message: ActiveAgent::ActionPrompt::Message.new(content: "Test direct embedding")
      )
      response = agent.embed

      assert_not_nil response
      assert_instance_of ActiveAgent::GenerationProvider::Response, response
    end
  end
end
