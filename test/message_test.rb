# test/active_agent/action_prompt/message_test.rb

require_relative "test_helper"
require "active_agent/action_prompt/message"

describe ActiveAgent::ActionPrompt::Message do
  let(:valid_attributes) { {content: "Hello", role: "user"} }

  it "initializes with valid attributes" do
    message = ActiveAgent::ActionPrompt::Message.new(valid_attributes)
    assert_equal "Hello", message.content
    assert_equal "user", message.role
  end

  it "has default values" do
    message = ActiveAgent::ActionPrompt::Message.new
    assert_equal "", message.content
    assert_equal "system", message.role
    assert_empty message.requested_actions
    assert_empty message.params
  end

  it "validates role" do
    assert_raises(ArgumentError) do
      ActiveAgent::ActionPrompt::Message.new(role: "invalid_role")
    end
  end

  it "checks for requested actions" do
    message = ActiveAgent::ActionPrompt::Message.new
    refute message.actions_requested?

    message.requested_actions << "action1"
    assert message.actions_requested?
  end

  it "is not an action call" do
    message = ActiveAgent::ActionPrompt::Message.new
    refute message.action_call?
  end

  it "converts to string" do
    message = ActiveAgent::ActionPrompt::Message.new(content: "Hello")
    assert_equal "Hello", message.to_s
  end

  it "converts to hash" do
    message = ActiveAgent::ActionPrompt::Message.new(valid_attributes)
    expected_hash = {content: "Hello", role: "user"}
    assert_equal expected_hash, message.to_h
  end

  it "allows all valid roles" do
    ActiveAgent::ActionPrompt::Message::VALID_ROLES.each do |role|
      message = ActiveAgent::ActionPrompt::Message.new(role: role)
      assert_equal role, message.role
    end
  end
end
