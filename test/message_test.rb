require "minitest/autorun"
require_relative "../lib/active_agent/action_prompt/message"

class MessageTest < Minitest::Test
  def test_initialize_with_defaults
    message = ActiveAgent::ActionPrompt::Message.new
    assert_equal "", message.content
    assert_equal "user", message.role
    assert_nil message.name
    assert_nil message.action_requested
    assert_empty message.requested_actions
  end

  def test_initialize_with_attributes
    attributes = {
      content: "Hello",
      role: "assistant",
      name: "TestName",
      function_call: "TestFunction",
      tool_calls: ["Tool1", "Tool2"]
    }
    message = ActiveAgent::ActionPrompt::Message.new(attributes)
    assert_equal "Hello", message.content
    assert_equal "assistant", message.role
    assert_equal "TestName", message.name
    assert_equal "TestFunction", message.action_requested
    assert_equal ["Tool1", "Tool2"], message.requested_actions
  end

  def test_to_h
    attributes = {
      content: "Hello",
      role: "assistant",
      name: "TestName",
      function_call: "TestFunction",
      tool_calls: ["Tool1", "Tool2"]
    }
    message = ActiveAgent::ActionPrompt::Message.new(attributes)
    expected_hash = {
      role: "assistant",
      content: "Hello",
      name: "TestName",
      action_requested: "TestFunction",
      requested_actions: ["Tool1", "Tool2"]
    }
    assert_equal expected_hash, message.to_h
  end

  def test_perform_actions
    action1 = Minitest::Mock.new
    action1.expect :call, nil, [ActiveAgent::ActionPrompt::Message]
    action2 = Minitest::Mock.new
    action2.expect :call, nil, [ActiveAgent::ActionPrompt::Message]

    message = ActiveAgent::ActionPrompt::Message.new(tool_calls: [action1, action2])
    message.perform_actions

    action1.verify
    action2.verify
  end

  def test_action_requested?
    message = ActiveAgent::ActionPrompt::Message.new(function_call: "TestFunction")
    assert message.action_requested?

    message = ActiveAgent::ActionPrompt::Message.new(tool_calls: ["Tool1"])
    assert message.action_requested?

    message = ActiveAgent::ActionPrompt::Message.new
    refute message.action_requested?
  end

  def test_validate_role
    assert_raises(ArgumentError) do
      ActiveAgent::ActionPrompt::Message.new(role: "invalid_role")
    end
  end
end
