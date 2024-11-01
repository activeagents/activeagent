require "active_agent/action_prompt/prompt"

class ActiveAgent::ActionPrompt::PromptTest < ActiveSupport::TestCase
  def setup
    @prompt = ActiveAgent::ActionPrompt::Prompt.new
  end

  test "initializes with default values" do
    assert_empty @prompt.actions
    assert_empty @prompt.instructions
    assert_instance_of ActiveAgent::ActionPrompt::Message, @prompt.message
    assert_empty @prompt.messages
    assert_empty @prompt.params
  end

  test "sets instructions as a system message" do
    prompt = ActiveAgent::ActionPrompt::Prompt.new(instructions: "Test instructions")
    assert_instance_of ActiveAgent::ActionPrompt::Message, prompt.instructions
    assert_equal "Test instructions", prompt.instructions.content
    assert_equal :system, prompt.instructions.role
  end

  test "sets message as a user message" do
    prompt = ActiveAgent::ActionPrompt::Prompt.new(message: "Test message")
    assert_instance_of ActiveAgent::ActionPrompt::Message, prompt.message
    assert_equal "Test message", prompt.message.content
    assert_equal :user, prompt.message.role
  end

  test "sets messages as user messages" do
    prompt = ActiveAgent::ActionPrompt::Prompt.new(messages: ["Message 1", "Message 2"])
    assert_equal 2, prompt.messages.size
    assert prompt.messages.all? { |msg| msg.is_a?(ActiveAgent::ActionPrompt::Message) }
    assert prompt.messages.all? { |msg| msg.role == :user }
  end

  test "to_s returns message content" do
    prompt = ActiveAgent::ActionPrompt::Prompt.new(message: "Test message")
    assert_equal "Test message", prompt.to_s
  end

  test "to_h returns hash representation" do
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      actions: [:action1],
      instructions: "Test instructions",
      message: "Test message",
      messages: ["Message 1"]
    )
    expected = {
      actions: [:action1],
      instructions: "Test instructions",
      message: {content: "Test message", role: :user},
      messages: [{content: "Message 1", role: :user}]
    }
    assert_equal expected, prompt.to_h
  end
end
