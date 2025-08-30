require "test_helper"
require "solid_agent"

class SolidAgent::Models::PromptContextTest < ActiveSupport::TestCase
  setup do
    @agent = SolidAgent::Models::Agent.create!(
      class_name: "TestAgent",
      display_name: "Test Agent",
      status: "active"
    )
    
    @context = SolidAgent::Models::PromptContext.create!(
      agent: @agent,
      status: "active",
      context_type: "runtime",
      started_at: Time.current
    )
  end
  
  test "validates required fields" do
    context = SolidAgent::Models::PromptContext.new
    assert_not context.valid?
    assert_includes context.errors[:agent], "must exist"
  end
  
  test "validates status inclusion" do
    @context.status = "invalid"
    assert_not @context.valid?
    assert_includes @context.errors[:status], "is not included in the list"
  end
  
  test "validates context_type inclusion" do
    @context.context_type = "invalid"
    assert_not @context.valid?
    assert_includes @context.errors[:context_type], "is not included in the list"
  end
  
  test "supports polymorphic contextual association" do
    user = User.create!(name: "Test User") # Assuming User model exists
    context = SolidAgent::Models::PromptContext.create!(
      agent: @agent,
      contextual: user
    )
    
    assert_equal user, context.contextual
    assert_equal "User", context.contextual_type
    assert_equal user.id, context.contextual_id
  end
  
  test "adds messages with correct roles" do
    message = @context.add_message(role: "user", content: "Hello")
    
    assert_equal "user", message.role
    assert_equal "Hello", message.content
    assert_equal 0, message.position
    assert_equal @context, message.prompt_context
  end
  
  test "adds system messages" do
    message = @context.add_system_message("You are helpful")
    
    assert_equal "system", message.role
    assert_equal "You are helpful", message.content
  end
  
  test "adds developer messages as special system messages" do
    message = @context.add_developer_message("Debug mode enabled")
    
    assert_equal "system", message.role
    assert_equal "Debug mode enabled", message.content
    assert_equal "developer", message.metadata["source"]
  end
  
  test "adds assistant messages with requested actions" do
    message = @context.add_assistant_message(
      "I'll search for that",
      requested_actions: [
        { name: "search", id: "call_abc", arguments: { q: "test" } }
      ]
    )
    
    assert_equal "assistant", message.role
    assert_equal 1, message.actions.count
    
    action = message.actions.first
    assert_equal "search", action.action_name
    assert_equal "call_abc", action.action_id
    assert_equal "pending", action.status
  end
  
  test "adds tool messages and marks actions as executed" do
    # First create an assistant message with action
    assistant_msg = @context.add_assistant_message(
      "Searching...",
      requested_actions: [{ name: "search", id: "call_xyz", arguments: {} }]
    )
    action = assistant_msg.actions.first
    
    # Add tool result message
    tool_msg = @context.add_tool_message(
      "Search results: 10 items found",
      action_id: "call_xyz"
    )
    
    assert_equal "tool", tool_msg.role
    action.reload
    assert_equal "executed", action.status
    assert_equal tool_msg.id, action.result_message_id
  end
  
  test "transitions through status lifecycle" do
    assert_equal "active", @context.status
    
    @context.process!
    assert_equal "processing", @context.status
    
    @context.complete!
    assert_equal "completed", @context.status
    assert_not_nil @context.completed_at
  end
  
  test "handles failure with error message" do
    @context.fail!("Connection timeout")
    
    assert_equal "failed", @context.status
    assert_equal "Connection timeout", @context.metadata["error"]
    assert_not_nil @context.completed_at
  end
  
  test "calculates duration metrics" do
    @context.update!(
      started_at: 2.seconds.ago,
      completed_at: Time.current
    )
    
    assert_in_delta 2.0, @context.duration, 0.1
  end
  
  test "counts messages and actions" do
    @context.add_user_message("Question 1")
    @context.add_assistant_message(
      "Answer 1",
      requested_actions: [
        { name: "tool1", id: "1", arguments: {} },
        { name: "tool2", id: "2", arguments: {} }
      ]
    )
    @context.add_user_message("Question 2")
    
    assert_equal 3, @context.message_count
    assert_equal 2, @context.actions.count
    assert @context.has_tool_calls?
  end
  
  test "finds or creates context for external ID" do
    context = SolidAgent::Models::PromptContext.find_or_create_for_context(
      "session_123",
      TestAgent,
      context_type: "api_request"
    )
    
    assert_equal "session_123", context.external_id
    assert_equal "api_request", context.context_type
    
    # Should find existing on second call
    context2 = SolidAgent::Models::PromptContext.find_or_create_for_context(
      "session_123",
      TestAgent
    )
    
    assert_equal context.id, context2.id
  end
  
  test "creates from ActionPrompt::Prompt object" do
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      agent_class: TestAgent,
      action_name: "search",
      messages: [
        ActiveAgent::ActionPrompt::Message.new(role: :system, content: "Be helpful"),
        ActiveAgent::ActionPrompt::Message.new(role: :user, content: "Find docs")
      ],
      multimodal: false,
      actions: ["search", "browse"]
    )
    
    agent_instance = TestAgent.new
    context = SolidAgent::Models::PromptContext.create_from_prompt(prompt, agent_instance)
    
    assert_equal 2, context.messages.count
    assert_equal "tool_execution", context.context_type
    assert_equal "search", context.metadata["action_name"]
    assert_equal ["search", "browse"], context.metadata["has_actions"]
  end
  
  test "converts back to ActionPrompt::Prompt" do
    @context.add_system_message("Instructions")
    @context.add_user_message("Query")
    
    prompt = @context.to_prompt
    
    assert_instance_of ActiveAgent::ActionPrompt::Prompt, prompt
    assert_equal 2, prompt.messages.count
    assert_equal :system, prompt.messages.first.role
    assert_equal :user, prompt.messages.second.role
  end
  
  test "scopes work correctly" do
    active = SolidAgent::Models::PromptContext.create!(agent: @agent, status: "active")
    processing = SolidAgent::Models::PromptContext.create!(agent: @agent, status: "processing")
    completed = SolidAgent::Models::PromptContext.create!(agent: @agent, status: "completed")
    failed = SolidAgent::Models::PromptContext.create!(agent: @agent, status: "failed")
    
    assert_includes SolidAgent::Models::PromptContext.active, active
    assert_includes SolidAgent::Models::PromptContext.processing, processing
    assert_includes SolidAgent::Models::PromptContext.completed, completed
    assert_includes SolidAgent::Models::PromptContext.failed, failed
  end
end

# Stub classes for testing
class TestAgent < ActiveAgent::Base
end

class User < ActiveRecord::Base
  self.table_name = "users"
end unless defined?(User)