require "minitest/autorun"
require_relative "../lib/active_agent/action_prompt/prompt"
require_relative "../lib/active_agent/action_prompt/message"

class PromptTest < Minitest::Test
  def setup
    @prompt = ActiveAgent::ActionPrompt::Prompt.new(
      actions: ["action1", "action2"],
      content_type: "text/plain",
      instructions: "These are the instructions",
      message: ActiveAgent::ActionPrompt::Message.new(content: "This is a message", role: :user),
      messages: [],
      params: {key: "value"},
      mime_version: "1.0",
      charset: "UTF-8",
      context: ["context1", "context2"]
    )
  end

  def test_initialize
    assert_equal ["action1", "action2"], @prompt.actions
    assert_equal "text/plain", @prompt.content_type
    assert_equal "These are the instructions", @prompt.instructions
    assert_equal "This is a message", @prompt.message.content
    assert_equal @prompt.messages.size, 2
    assert_equal "value", @prompt.params[:key]
    assert_equal "1.0", @prompt.mime_version
    assert_equal "UTF-8", @prompt.charset
    assert_equal ["context1", "context2"], @prompt.context
  end

  def test_to_s
    assert_equal "This is a message", @prompt.message.content
  end

  def test_add_part
    part = {body: "Part body", content_type: "text/plain", charset: "UTF-8"}
    @prompt.add_part(part)
    assert_equal 1, @prompt.instance_variable_get(:@parts).size
    assert_equal "Part body", @prompt.instance_variable_get(:@parts).first.message.content
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
      message: {role: :user, content: "This is a message"},
      messages: [
        {role: :system, content: "These are the instructions"},
        {role: :user, content: "This is a message"}
      ],
      headers: {}, context: ["context1", "context2"]
    }
    assert_equal expected_hash, @prompt.to_h
  end

  def test_headers
    @prompt.headers({"Content-Type" => "application/json"})
    assert_equal "application/json", @prompt.instance_variable_get(:@headers)["Content-Type"]
  end
end
