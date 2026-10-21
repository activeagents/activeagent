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
    result = service_for(tools: %w[terminal], approval_required_tools: []).execute_tool("run_command", command: "ls")

    assert_equal ActionAgent::CheckoutTools::NO_CHECKOUT, result[:error]
  end

  # The functions with side effects outside the conversation wait for a
  # person unless the agent's list says otherwise, whichever way their
  # capability was enabled: a template and the agents API bring no list.
  test "a capability's side-effecting functions wait for approval unless the save names its own list" do
    agent = ActionAgent::Agent.create!(name: "Gained", provider: "mock", model: "mock", tools: %w[terminal filesystem edit database slack translate])
    assert_equal %w[run_command write_file edit_file slack_post_message], agent.approval_required_tools

    agent.update!(tools: agent.tools + %w[code], approval_required_tools: %w[edit_file])
    assert_equal %w[edit_file], agent.approval_required_tools, "a list the save brought is kept as given"

    agent.update!(tools: %w[terminal], approval_required_tools: [])
    agent.update!(tools: %w[terminal slack])
    assert_equal %w[slack_post_message], agent.approval_required_tools, "a capability gained without a list joins it"

    agent.update!(name: "Still gained")
    assert_equal %w[slack_post_message], agent.approval_required_tools, "a save that gains nothing adds nothing"

    trusted = ActionAgent::Agent.create!(name: "Trusted", provider: "mock", model: "mock", tools: %w[terminal], approval_required_tools: [])
    assert_equal [], trusted.approval_required_tools
  end

  test "a side-effecting function waits for approval in a run by default" do
    result = service_for(tools: %w[terminal]).execute_tool("run_command", command: "ls")

    assert_kind_of ActiveAgent::InputRequest, result
    assert_equal :confirm, result.kind
    assert_match(/run_command/, result.prompt)
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

    service = service_for(tools: %w[slack], approval_required_tools: [])
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
