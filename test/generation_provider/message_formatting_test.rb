# frozen_string_literal: true

require "test_helper"
require "active_agent/action_prompt/message"
require "active_agent/action_prompt/action"
require "active_agent/generation_provider/message_formatting"

class MessageFormattingTest < ActiveSupport::TestCase
  class TestProvider
    include ActiveAgent::GenerationProvider::MessageFormatting
  end
  
  setup do
    @provider = TestProvider.new
    @message = ActiveAgent::ActionPrompt::Message.new(
      role: :user,
      content: "Test content"
    )
  end
  
  test "provider_messages formats multiple messages" do
    messages = [
      ActiveAgent::ActionPrompt::Message.new(role: :user, content: "Hello"),
      ActiveAgent::ActionPrompt::Message.new(role: :assistant, content: "Hi there")
    ]
    
    formatted = @provider.provider_messages(messages)
    
    assert_equal 2, formatted.length
    assert_equal "user", formatted[0][:role]
    assert_equal "Hello", formatted[0][:content]
    assert_equal "assistant", formatted[1][:role]
    assert_equal "Hi there", formatted[1][:content]
  end
  
  test "format_message creates base message structure" do
    formatted = @provider.send(:format_message, @message)
    
    assert_equal "user", formatted[:role]
    assert_equal "Test content", formatted[:content]
  end
  
  test "convert_role converts role to string" do
    assert_equal "user", @provider.send(:convert_role, :user)
    assert_equal "assistant", @provider.send(:convert_role, :assistant)
    assert_equal "system", @provider.send(:convert_role, "system")
    assert_equal "tool", @provider.send(:convert_role, :tool)
  end
  
  test "format_content handles text content" do
    @message.content_type = "text"
    assert_equal "Test content", @provider.send(:format_content, @message)
  end
  
  test "format_content handles image_url content type" do
    @message.content_type = "image_url"
    @message.content = "https://example.com/image.jpg"
    
    # Default implementation returns content as-is
    result = @provider.send(:format_content, @message)
    assert_equal "https://example.com/image.jpg", result
  end
  
  test "format_content handles multipart/mixed content type" do
    @message.content_type = "multipart/mixed"
    @message.content = ["part1", "part2"]
    
    result = @provider.send(:format_content, @message)
    assert_equal ["part1", "part2"], result
  end
  
  test "format_multimodal_content handles array content" do
    @message.content = [
      { type: "text", content: "Hello" },
      { type: "image", content: "image_url" }
    ]
    
    result = @provider.send(:format_multimodal_content, @message)
    assert_equal 2, result.length
  end
  
  test "add_tool_fields adds tool calls for assistant messages" do
    @message.role = :assistant
    @message.action_requested = true
    
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "tool_1",
      name: "test_tool",
      params: { key: "value" }
    )
    @message.requested_actions = [action]
    
    formatted = {}
    @provider.send(:add_tool_fields, formatted, @message)
    
    assert formatted[:tool_calls]
    assert_equal 1, formatted[:tool_calls].length
    assert_equal "function", formatted[:tool_calls][0][:type]
    assert_equal "test_tool", formatted[:tool_calls][0][:function][:name]
  end
  
  test "add_tool_fields adds raw actions for assistant messages" do
    @message.role = :assistant
    @message.raw_actions = [{ type: "function", name: "raw_tool" }]
    
    formatted = {}
    @provider.send(:add_tool_fields, formatted, @message)
    
    assert_equal [{ type: "function", name: "raw_tool" }], formatted[:tool_calls]
  end
  
  test "add_tool_fields adds tool metadata for tool messages" do
    @message.role = :tool
    @message.action_id = "tool_123"
    @message.action_name = "my_tool"
    
    formatted = {}
    @provider.send(:add_tool_fields, formatted, @message)
    
    assert_equal "tool_123", formatted[:tool_call_id]
    assert_equal "my_tool", formatted[:name]
  end
  
  test "add_metadata_fields can be overridden" do
    class MetadataProvider < TestProvider
      protected
      def add_metadata_fields(base_message, message)
        base_message[:timestamp] = "2024-01-01"
      end
    end
    
    provider = MetadataProvider.new
    formatted = provider.send(:format_message, @message)
    
    assert_equal "2024-01-01", formatted[:timestamp]
  end
  
  test "format_tool_calls formats multiple actions" do
    actions = [
      ActiveAgent::ActionPrompt::Action.new(id: "1", name: "tool1", params: { a: 1 }),
      ActiveAgent::ActionPrompt::Action.new(id: "2", name: "tool2", params: { b: 2 })
    ]
    
    formatted = @provider.send(:format_tool_calls, actions)
    
    assert_equal 2, formatted.length
    assert_equal "tool1", formatted[0][:function][:name]
    assert_equal "tool2", formatted[1][:function][:name]
    assert_equal '{"a":1}', formatted[0][:function][:arguments]
    assert_equal '{"b":2}', formatted[1][:function][:arguments]
  end
  
  test "format_single_tool_call creates OpenAI format" do
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "call_123",
      name: "get_weather",
      params: { location: "NYC" }
    )
    
    formatted = @provider.send(:format_single_tool_call, action)
    
    assert_equal "function", formatted[:type]
    assert_equal "get_weather", formatted[:function][:name]
    assert_equal '{"location":"NYC"}', formatted[:function][:arguments]
    assert_equal "call_123", formatted[:id]
  end
  
  test "format_single_tool_call handles string params" do
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "call_456",
      name: "test",
      params: '{"already":"json"}'
    )
    
    formatted = @provider.send(:format_single_tool_call, action)
    assert_equal '{"already":"json"}', formatted[:function][:arguments]
  end
  
  test "compact removes nil values from formatted message" do
    @message.action_id = nil
    @message.action_name = nil
    
    formatted = @provider.send(:format_message, @message)
    
    assert_not formatted.key?(:tool_call_id)
    assert_not formatted.key?(:name)
  end
  
  test "provider can override format_image_content" do
    class ImageProvider < TestProvider
      protected
      def format_image_content(message)
        [{ type: "image_url", url: message.content }]
      end
    end
    
    provider = ImageProvider.new
    @message.content_type = "image_url"
    @message.content = "https://example.com/pic.jpg"
    
    result = provider.send(:format_content, @message)
    assert_equal [{ type: "image_url", url: "https://example.com/pic.jpg" }], result
  end
  
  test "format_content_item default implementation" do
    item = { type: "text", content: "Hello" }
    result = @provider.send(:format_content_item, item)
    assert_equal item, result
  end
end