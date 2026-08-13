# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# Collapsed interaction rows in the dashboard carry two lines — what the stream
# was asked, and what it finally answered — the same pair a collapsed trace row
# shows. Both sources of an interaction have to produce them, or a list mixing
# the two reads differently depending on where each row came from.
class InteractionPreviewTest < ActionDispatch::IntegrationTest
  TelemetryTraceTest.ensure_table!

  def setup
    ActionAgent::AgentMessage.delete_all
    ActionAgent::AgentGeneration.delete_all
    ActionAgent::AgentContext.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  # A context reaches the API through the agent it belongs to, so every one of
  # these needs an owning agent to be listed at all.
  def create_context
    ActionAgent::AgentContext.create!(
      contextable: @agent,
      agent_name: "SupportAgent",
      action_name: "respond",
      total_input_tokens: 40,
      total_output_tokens: 60
    )
  end

  def interactions
    get "/activeagents/api/interactions"
    assert_response :success
    JSON.parse(response.body)["interactions"]
  end

  test "a context previews its opening prompt and its final answer" do
    context = create_context
    context.add_user_message("Where is order 88213?")
    context.add_assistant_message("Let me look that up.")
    context.add_user_message("Any update?")
    context.add_assistant_message("The carrier never scanned it in.")

    preview = interactions.first["preview"]

    # The ends of the stream, not its middle: the turns in between are tool
    # traffic and follow-ups that a one-line preview can't summarize.
    assert_equal "Where is order 88213?", preview["input"]
    assert_equal "The carrier never scanned it in.", preview["output"]
  end

  test "a tool-calling assistant turn is skipped for the answer" do
    context = create_context
    context.add_user_message("Where is order 88213?")
    context.add_assistant_message("The carrier never scanned it in.")
    # A turn that only carries a tool call has no prose to show.
    context.messages.create!(role: "assistant", content: "")

    assert_equal "The carrier never scanned it in.", interactions.first.dig("preview", "output")
  end

  test "previews are nil when a stream captured no content" do
    create_context

    preview = interactions.first["preview"]

    assert_nil preview["input"]
    assert_nil preview["output"]
  end

  test "each context gets its own preview" do
    first = create_context
    first.add_user_message("Where is order 88213?")
    second = create_context
    second.add_user_message("Cancel my subscription")

    previews = interactions.to_h { |row| [ row["id"], row.dig("preview", "input") ] }

    assert_equal "Where is order 88213?", previews[first.id]
    assert_equal "Cancel my subscription", previews[second.id]
  end

  test "a reported trace previews from its captured span contents" do
    ActionAgent::TelemetryTrace.create_from_payload({
      "trace_id" => SecureRandom.hex(16),
      "service_name" => "customer-app",
      "timestamp" => Time.current.iso8601(6),
      "spans" => [
        {
          "span_id" => "root1", "parent_span_id" => nil, "name" => "ReportedAgent.respond",
          "type" => "root", "duration_ms" => 1000.0, "status" => "OK",
          "attributes" => { "agent.class" => "ReportedAgent", "agent.action" => "respond" }
        },
        {
          "span_id" => "llm1", "parent_span_id" => "root1", "name" => "llm.generate",
          "type" => "llm", "duration_ms" => 900.0, "status" => "OK",
          "attributes" => {
            "llm.model" => "mock-model",
            "llm.prompt" => "Summarize   the\nrelease notes",
            "llm.completion" => "Three fixes and one new setting."
          }
        }
      ]
    })

    preview = interactions.find { |row| row["source"] == "telemetry" }["preview"]

    # Whitespace collapses so the line stays one line whatever the prompt did.
    assert_equal "Summarize the release notes", preview["input"]
    assert_equal "Three fixes and one new setting.", preview["output"]
  end

  test "a preview is clipped rather than sending the whole conversation" do
    context = create_context
    context.add_user_message("x" * 5_000)

    input = interactions.first.dig("preview", "input")

    # Length includes the omission ActiveSupport appends.
    assert_equal ActionAgent::InteractionPreview::LIMIT, input.length
    assert input.end_with?("...")
  end
end
