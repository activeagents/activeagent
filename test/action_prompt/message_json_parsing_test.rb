# frozen_string_literal: true

require "test_helper"
require "active_agent/action_prompt/message"

class MessageJsonParsingTest < ActiveSupport::TestCase
  test "automatically parses JSON content when content_type is application/json" do
    json_string = '{"name": "John", "age": 30, "active": true}'

    message = ActiveAgent::ActionPrompt::Message.new(
      content: json_string,
      content_type: "application/json",
      role: :assistant
    )

    assert message.content.is_a?(Hash)
    assert_equal "John", message.content["name"]
    assert_equal 30, message.content["age"]
    assert_equal true, message.content["active"]

    # Raw content should still be available
    assert_equal json_string, message.raw_content
  end

  test "returns raw content if JSON parsing fails" do
    invalid_json = "{invalid json}"

    message = ActiveAgent::ActionPrompt::Message.new(
      content: invalid_json,
      content_type: "application/json",
      role: :assistant
    )

    assert message.content.is_a?(String)
    assert_equal invalid_json, message.content
    assert_equal invalid_json, message.raw_content
  end

  test "does not parse content when content_type is not JSON" do
    json_like_string = '{"looks": "like json"}'

    message = ActiveAgent::ActionPrompt::Message.new(
      content: json_like_string,
      content_type: "text/plain",
      role: :assistant
    )

    assert message.content.is_a?(String)
    assert_equal json_like_string, message.content
  end

  test "handles empty content gracefully" do
    message = ActiveAgent::ActionPrompt::Message.new(
      content: "",
      content_type: "application/json",
      role: :assistant
    )

    assert_equal "", message.content
    assert_equal "", message.raw_content
  end

  test "preserves non-string content as-is" do
    hash_content = { already: "parsed" }

    message = ActiveAgent::ActionPrompt::Message.new(
      content: hash_content,
      content_type: "application/json",
      role: :assistant
    )

    assert_equal hash_content, message.content
    assert_equal hash_content, message.raw_content
  end
end
