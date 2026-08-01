# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/mock_provider"

# Tool-loop safety: process_prompt_finished re-enters resolve_prompt while
# the model keeps emitting tool calls. The max_tool_turns cap bounds that
# recursion and finishes cleanly with the messages gathered so far.
class BaseProviderToolTurnsTest < ActiveSupport::TestCase
  # A mock provider whose "model" emits a tool call on every response —
  # unbounded, this would recurse forever.
  class LoopingMockProvider < ActiveAgent::Providers::MockProvider
    # Type resolution (service_name/namespace) derives from the class
    # name; keep the Mock identity for this test-local subclass.
    def self.name = "ActiveAgent::Providers::MockProvider"

    attr_reader :tool_rounds

    def process_prompt_finished_extract_function_calls
      [ { name: "spin", input: {}, id: "call_#{object_id}_#{@tool_rounds}" } ]
    end

    def process_function_calls(_calls)
      @tool_rounds = (@tool_rounds || 0) + 1
      message_stack.push({ role: "user", content: "tool result #{@tool_rounds}" })
    end
  end

  test "max_tool_turns bounds the tool-calling recursion" do
    provider = LoopingMockProvider.new(
      messages: [ { role: "user", content: "go" } ],
      max_tool_turns: 3
    )

    response = provider.prompt

    assert_equal 3, provider.tool_rounds
    assert response.present?, "capped loop should still return a response"
    assert response.messages.any?
  end

  test "hitting the cap emits a tool_turns_exceeded notification" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("tool_turns_exceeded.active_agent") do |*, payload|
      events << payload
    end

    LoopingMockProvider.new(
      messages: [ { role: "user", content: "go" } ],
      max_tool_turns: 2
    ).prompt

    assert_equal 1, events.length
    assert_equal 2, events.first[:limit]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "the default cap applies when none is configured" do
    provider = LoopingMockProvider.new(messages: [ { role: "user", content: "go" } ])

    provider.prompt

    assert_equal ActiveAgent::Providers::BaseProvider::DEFAULT_MAX_TOOL_TURNS, provider.tool_rounds
  end

  test "generations without tool calls are unaffected" do
    provider = ActiveAgent::Providers::MockProvider.new(
      messages: [ { role: "user", content: "hello there" } ]
    )

    response = provider.prompt

    assert response.message.content.present?
  end
end
