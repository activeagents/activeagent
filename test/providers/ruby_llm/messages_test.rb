# frozen_string_literal: true

require "test_helper"

# Ensure RubyLLM stubs are loaded before the provider
require_relative "ruby_llm_provider_test"

class RubyLLMMessagesTest < ActiveSupport::TestCase
  # --- Messages::Base ---

  test "Base message has role and content attributes" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Base.new(role: "user", content: "Hello")
    assert_equal "user", msg.role
    assert_equal "Hello", msg.content
  end

  test "Base message validates role presence" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Base.new(content: "Hello")
    refute msg.valid?
    assert_includes msg.errors[:role], "can't be blank"
  end

  test "Base to_common returns hash with role and content" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Base.new(role: "user", content: "Hello")
    common = msg.to_common

    assert_equal "user", common[:role]
    assert_equal "Hello", common[:content]
    assert_nil common[:name]
  end

  test "Base to_common extracts text from array content" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Base.new(
      role: "user",
      content: [
        { type: "text", text: "Hello" },
        { type: "image_url", image_url: { url: "http://example.com/img.png" } },
        { type: "text", text: "World" }
      ]
    )
    common = msg.to_common

    assert_equal "Hello\nWorld", common[:content]
  end

  test "Base to_common converts non-string non-array content via to_s" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Base.new(role: "user", content: 42)
    common = msg.to_common

    assert_equal "42", common[:content]
  end

  # --- Messages::User ---

  test "User message defaults role to user" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::User.new(content: "Hello")
    assert_equal "user", msg.role
  end

  test "User message validates content presence" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::User.new(content: nil)
    refute msg.valid?
    assert_includes msg.errors[:content], "can't be blank"
  end

  # --- Messages::System ---

  test "System message defaults role to system" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::System.new(content: "Be helpful.")
    assert_equal "system", msg.role
  end

  test "System message validates content presence" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::System.new(content: nil)
    refute msg.valid?
    assert_includes msg.errors[:content], "can't be blank"
  end

  # --- Messages::Assistant ---

  test "Assistant message defaults role to assistant" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Assistant.new(content: "Hi there!")
    assert_equal "assistant", msg.role
  end

  test "Assistant message validates content presence unless tool_calls" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Assistant.new(content: nil)
    refute msg.valid?

    msg_with_tools = ActiveAgent::Providers::RubyLLM::Messages::Assistant.new(
      content: nil,
      tool_calls: [{ id: "call_1", function: { name: "test" } }]
    )
    assert msg_with_tools.valid?
  end

  test "Assistant message accepts tool_calls" do
    tool_calls = [{ id: "call_1", type: "function", function: { name: "get_weather", arguments: '{}' } }]
    msg = ActiveAgent::Providers::RubyLLM::Messages::Assistant.new(content: "", tool_calls: tool_calls)

    assert_equal tool_calls, msg.tool_calls
  end

  test "Assistant message drops extra API response fields" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Assistant.new(
      content: "Hello",
      usage: { tokens: 10 },
      id: "msg_123",
      model: "gpt-4o",
      stop_reason: "end_turn",
      stop_sequence: nil,
      type: "message",
      input_tokens: 5,
      output_tokens: 3
    )

    assert_equal "Hello", msg.content
    assert_equal "assistant", msg.role
  end

  # --- Messages::Tool ---

  test "Tool message defaults role to tool" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Tool.new(
      content: '{"result": "ok"}',
      tool_call_id: "call_123"
    )
    assert_equal "tool", msg.role
    assert_equal "call_123", msg.tool_call_id
  end

  test "Tool message to_common includes tool_call_id" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Tool.new(
      content: '{"temp": 72}',
      tool_call_id: "call_456"
    )
    common = msg.to_common

    assert_equal "tool", common[:role]
    assert_equal '{"temp": 72}', common[:content]
    assert_equal "call_456", common[:tool_call_id]
  end

  test "Tool message to_common omits tool_call_id when nil" do
    msg = ActiveAgent::Providers::RubyLLM::Messages::Tool.new(content: "result")
    common = msg.to_common

    refute common.key?(:tool_call_id)
  end

  # --- Messages::MessageType ---

  test "MessageType casts string to User message" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = type.cast("Hello world")

    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::User, msg
    assert_equal "Hello world", msg.content
  end

  test "MessageType casts hash with user role" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = type.cast({ role: "user", content: "Hi" })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::User, msg
  end

  test "MessageType casts hash with assistant role" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = type.cast({ role: "assistant", content: "Hello" })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::Assistant, msg
  end

  test "MessageType casts hash with system role" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = type.cast({ role: "system", content: "Be helpful" })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::System, msg
  end

  test "MessageType casts hash with tool role" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = type.cast({ role: "tool", content: '{"result": "ok"}', tool_call_id: "call_1" })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::Tool, msg
    assert_equal "call_1", msg.tool_call_id
  end

  test "MessageType casts hash without role as User" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = type.cast({ content: "Hello" })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::User, msg
  end

  test "MessageType casts nil to nil" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    assert_nil type.cast(nil)
  end

  test "MessageType raises for unknown role" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new

    assert_raises(ArgumentError) do
      type.cast({ role: "unknown", content: "test" })
    end
  end

  test "MessageType raises for unsupported type" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new

    assert_raises(ArgumentError) do
      type.cast(42)
    end
  end

  test "MessageType passes through Base instances" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    original = ActiveAgent::Providers::RubyLLM::Messages::User.new(content: "Hi")
    result = type.cast(original)

    assert_same original, result
  end

  test "MessageType serializes Base instance" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = ActiveAgent::Providers::RubyLLM::Messages::User.new(content: "Hello")
    serialized = type.serialize(msg)

    assert_kind_of Hash, serialized
    assert_equal "user", serialized[:role]
    assert_equal "Hello", serialized[:content]
  end

  test "MessageType serializes hash as-is" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    hash = { role: "user", content: "Hello" }
    assert_equal hash, type.serialize(hash)
  end

  test "MessageType serializes nil as nil" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    assert_nil type.serialize(nil)
  end

  test "MessageType deserialize delegates to cast" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessageType.new
    msg = type.deserialize({ role: "user", content: "Hello" })

    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::User, msg
  end

  # --- Messages::MessagesType ---

  test "MessagesType casts array of hashes" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessagesType.new
    result = type.cast([
      { role: "user", content: "Hello" },
      { role: "assistant", content: "Hi" }
    ])

    assert_equal 2, result.size
    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::User, result[0]
    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::Assistant, result[1]
  end

  test "MessagesType casts nil to nil" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessagesType.new
    assert_nil type.cast(nil)
  end

  test "MessagesType raises for non-array" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessagesType.new

    assert_raises(ArgumentError) do
      type.cast("not an array")
    end
  end

  test "MessagesType serializes and merges consecutive same-role messages" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessagesType.new
    messages = [
      ActiveAgent::Providers::RubyLLM::Messages::User.new(content: "Hello"),
      ActiveAgent::Providers::RubyLLM::Messages::User.new(content: " World"),
      ActiveAgent::Providers::RubyLLM::Messages::Assistant.new(content: "Hi")
    ]

    serialized = type.serialize(messages)

    # Two consecutive user messages should be merged
    assert_equal 2, serialized.size
  end

  test "MessagesType serializes nil to nil" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessagesType.new
    assert_nil type.serialize(nil)
  end

  test "MessagesType deserialize delegates to cast" do
    type = ActiveAgent::Providers::RubyLLM::Messages::MessagesType.new
    result = type.deserialize([{ role: "user", content: "Hello" }])

    assert_equal 1, result.size
    assert_kind_of ActiveAgent::Providers::RubyLLM::Messages::User, result[0]
  end
end
