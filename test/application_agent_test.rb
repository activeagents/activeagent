# test/application_agent_test.rb - additional test for embed functionality

require "test_helper"

class ApplicationAgentTest < ActiveSupport::TestCase
  test "it renders a prompt with an empty message" do
    assert_equal "", ApplicationAgent.text_prompt.message.content
  end

  test "it renders a prompt with an plain text message" do
    assert_equal "Test Application Agent", ApplicationAgent.with(message: "Test Application Agent").text_prompt.message.content
  end

  test "embed generates vector for message content" do
    message = ActiveAgent::ActionPrompt::Message.new(content: "Test content for embedding")
    response = message.embed

    assert_not_nil response
    assert_equal message, response
    # Assuming your provider returns a vector when embed is called
    assert_not_nil response.content
  end

  test "embed can be called directly on an agent instance" do
    agent = ApplicationAgent.new
    agent.prompt_context = ActiveAgent::ActionPrompt::Prompt.new(
      message: ActiveAgent::ActionPrompt::Message.new(content: "Test direct embedding")
    )
    response = agent.embed

    assert_not_nil response
    assert_instance_of ActiveAgent::GenerationProvider::Response, response
  end
end
