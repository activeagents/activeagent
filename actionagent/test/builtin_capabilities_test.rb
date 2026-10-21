# frozen_string_literal: true

require "test_helper"

# The capabilities the builder offers that act for the run rather than in
# AgentToolbox: the checkout tools, Slack, translate — routed by
# AgentExecutionService — and the instruction sets, composed into what a run
# executes under. Every capability in Agent::AVAILABLE_TOOLS has functions.
class BuiltinCapabilitiesTest < ActiveSupport::TestCase
  SLACK_TOKEN = "xoxb-1234-5678-abcdefghijkl"

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::ProviderKey.delete_all
  end

  def service_for(tools:, **attributes)
    agent = ActionAgent::Agent.create!({ name: "Capable", provider: "mock", model: "mock", tools: tools }.merge(attributes))
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :running)
    ActionAgent::AgentExecutionService.new(agent, run)
  end

  test "every capability the builder offers defines functions" do
    assert_empty ActionAgent::Agent::AVAILABLE_TOOLS - ActionAgent::AgentToolbox::DEFINITIONS.keys
    names = ActionAgent::AgentToolbox.definitions_for(%w[terminal filesystem edit database slack translate]).map { |d| d[:name] }
    assert_equal %w[run_command list_files read_file write_file edit_file query_database
      slack_list_channels slack_read_channel slack_post_message translate_text], names
  end

  test "a checkout tool in a run given no checkout says how to give it one" do
    result = service_for(tools: %w[terminal]).execute_tool("run_command", command: "ls")

    assert_equal ActionAgent::CheckoutTools::NO_CHECKOUT, result[:error]
  end

  test "translate_text generates on the run's own provider" do
    result = service_for(tools: %w[translate]).execute_tool("translate_text", text: "Hello", target_language: "Spanish")

    assert_nil result[:error]
    assert result[:translation].is_a?(String) && result[:translation].present?
    assert_equal "Spanish", result[:target_language]
    assert_match(/target_language/, service_for(tools: %w[translate]).execute_tool("translate_text", text: "Hi", target_language: "")[:error])
  end

  test "slack tools say how to connect Slack until a bot token is saved, then call the Web API with it" do
    service = service_for(tools: %w[slack])
    assert_equal ActionAgent::SlackTools::NOT_CONNECTED, service.execute_tool("slack_list_channels")[:error]

    ActionAgent::ProviderKey.create!(provider: "slack", credential: SLACK_TOKEN)
    stub_request(:post, "https://slack.com/api/chat.postMessage")
      .with(headers: { "Authorization" => "Bearer #{SLACK_TOKEN}" }, body: { channel: "C1", text: "Deployed" }.to_json)
      .to_return(body: { ok: true, channel: "C1", ts: "1700000000.0001" }.to_json)
    stub_request(:get, %r{\Ahttps://slack.com/api/conversations.history})
      .to_return(body: { ok: false, error: "not_in_channel" }.to_json)

    service = service_for(tools: %w[slack])
    assert_equal({ posted: true, channel: "C1", ts: "1700000000.0001" }, service.execute_tool("slack_post_message", channel: "C1", text: "Deployed"))
    assert_equal "Slack refused conversations.history: not_in_channel", service.execute_tool("slack_read_channel", channel: "C1")[:error]
  end

  test "a Slack connection holds a bot token and is a connection, not a model provider" do
    assert_includes ActionAgent::ProviderKey::CONNECTION_PROVIDERS, "slack"
    assert_not ActionAgent::ProviderKey.new(provider: "slack", credential: "sk-not-slack").valid?
    assert ActionAgent::ProviderKey.new(provider: "slack", credential: SLACK_TOKEN).valid?
  end

  test "instruction sets are composed into the instructions a run executes under" do
    agent = ActionAgent::Agent.new(name: "Stack", instructions: "Help with the shop.", instruction_sets: %w[rails unknown github])

    composed = agent.composed_instructions_for("ask")

    assert composed.start_with?("Help with the shop.\n\nConventions to follow:\n")
    assert_includes composed, ActionAgent::Agent::INSTRUCTION_SET_GUIDANCE["rails"]
    assert_includes composed, ActionAgent::Agent::INSTRUCTION_SET_GUIDANCE["github"]
    assert_nil ActionAgent::Agent.new(name: "Bare").composed_instructions_for("ask")
  end
end
