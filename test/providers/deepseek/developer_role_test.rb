# frozen_string_literal: true

require "test_helper"
# Through the provider entry point, so the OpenAI gem the transforms lean on is
# loaded the same way it is in production.
require "active_agent/providers/deepseek_provider"

# DeepSeek's API rejects any message role outside system, user, assistant, tool
# and latest_reminder. `developer` is the one ActiveAgent reaches for on its
# own — the OpenAI transforms express `instructions` as a developer message —
# so an agent using instructions fails against DeepSeek until it is folded into
# `system`.
class DeepseekDeveloperRoleTest < ActiveSupport::TestCase
  test "converts instructions into system messages, not developer ones" do
    request = build_request(instructions: "You are terse.")

    assert_equal [ { role: "system", content: "You are terse." } ], serialized_messages(request)
  end

  test "keeps instructions ahead of the messages they introduce" do
    request = build_request(instructions: "You are terse.", messages: [ { role: "user", content: "hi" } ])

    assert_equal %w[system user], serialized_messages(request).pluck(:role)
  end

  test "folds multiple instructions into one system message" do
    request = build_request(instructions: [ "First.", "Second." ])

    content = [ { type: "text", text: "First." }, { type: "text", text: "Second." } ]

    assert_equal [ { role: "system", content: } ], serialized_messages(request)
  end

  test "converts an explicitly passed developer message" do
    request = build_request(messages: [ { role: "developer", content: "Be terse." } ])

    assert_equal %w[system], serialized_messages(request).pluck(:role)
  end

  test "converts a developer message with string keys" do
    request = build_request(messages: [ { "role" => "developer", "content" => "Be terse." } ])

    assert_equal [ "system" ], serialized_messages(request).pluck(:role)
  end

  test "leaves the other roles alone" do
    messages = [
      { role: "user", content: "hi" },
      { role: "assistant", content: "hello" },
      { role: "tool", content: "result", tool_call_id: "call_1" }
    ]

    assert_equal %w[user assistant tool], serialized_messages(build_request(messages:)).pluck(:role)
  end

  test "sends no developer role for any supported input" do
    request = build_request(instructions: "Be terse.", messages: [ { role: "developer", content: "Also short." } ])

    refute_includes serialized_messages(request).pluck(:role), "developer"
  end

  private

  def build_request(**params)
    ActiveAgent::Providers::DeepSeek::Chat::Request.new(**params)
  end

  def serialized_messages(request)
    request.serialize[:messages]
  end
end
