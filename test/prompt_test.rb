require_relative "../lib/active_agent/action_prompt/prompt"
require_relative "../lib/active_agent/action_prompt/message"

class PromptTest < Minitest::Test
  def setup
    @prompt = ActiveAgent::ActionPrompt::Prompt.new(
      actions: ["action1", "action2"],
      body: "This is the body",
      content_type: "text/plain",
      instructions: "These are the instructions",
      message: ActiveAgent::ActionPrompt::Message.new(content: "Initial message", role: :user),
      messages: [ActiveAgent::ActionPrompt::Message.new(content: "Message 1", role: :user)],
      params: {key: "value"},
      mime_version: "1.0",
      charset: "UTF-8",
      context: ["context1", "context2"]
    )
  end

  def test_initialize
    assert_equal ["action1", "action2"], @prompt.actions
    assert_equal "This is the body", @prompt.body
    assert_equal "text/plain", @prompt.content_type
    assert_equal "These are the instructions", @prompt.instructions
    assert_equal "Initial message", @prompt.message.content
    assert_equal 1, @prompt.messages.size
    assert_equal "value", @prompt.params[:key]
    assert_equal "1.0", @prompt.mime_version
    assert_equal "UTF-8", @prompt.charset
    assert_equal ["context1", "context2"], @prompt.context
  end

  def test_to_s
    assert_equal "Initial message", @prompt.to_s
  end

  def test_add_part
    part = {body: "Part body", content_type: "text/plain", charset: "UTF-8"}
    @prompt.add_part(part)
    assert_equal 1, @prompt.instance_variable_get(:@parts).size
  end

  def test_multipart?
    refute @prompt.multipart?
    part = {body: "Part body", content_type: "text/plain", charset: "UTF-8"}
    @prompt.add_part(part)
    assert @prompt.multipart?
  end

  def test_to_h
    expected_hash = {
      actions: ["action1", "action2"],
      action: "",
      instructions: "These are the instructions",
      message: @prompt.message.to_h,
      messages: @prompt.messages.map(&:to_h),
      headers: {},
      context: ["context1", "context2"]
    }
    assert_equal expected_hash, @prompt.to_h
  end

  def test_headers
    @prompt.headers({"Content-Type" => "application/json"})
    assert_equal "application/json", @prompt.instance_variable_get(:@headers)["Content-Type"]
  end

  def test_set_messages
    @prompt.set_messages
    assert_equal 2, @prompt.messages.size
    assert_equal "These are the instructions", @prompt.messages.first.content
  end

  def test_set_message
    @prompt.set_message
    assert_equal "This is the body", @prompt.message.content
  end
end
