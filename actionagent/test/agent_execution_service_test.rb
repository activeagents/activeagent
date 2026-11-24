# frozen_string_literal: true

require "test_helper"

# Covers the path that builds the runtime agent class for a run.
#
# Every other execution test stops short of it — they assert a quota denial, a
# disabled-execution refusal, or the 202 from enqueuing the job — so the class
# body itself was never executed by the suite. It has two dependencies that
# only a stock install exposes: solid_agent has to be loaded (it is a
# transitive dependency, so Bundler installs it without requiring it), and
# has_context has to be told the engine's namespaced models, since it
# otherwise infers bare AgentContext/AgentMessage/AgentGeneration and resolves
# them against Object.
class AgentExecutionServiceTest < ActiveSupport::TestCase
  def setup
    ActionAgent::Agent.delete_all
  end

  def build_run
    agent = ActionAgent::Agent.create!(
      name: "Mocked",
      provider: "mock",
      model: "mock",
      instructions: "Be brief."
    )
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :pending)
    [ agent, run ]
  end

  test "solid_agent is loaded by requiring the gem" do
    assert defined?(SolidAgent), "actionagent must require solid_agent itself"
    assert defined?(SolidAgent::HasContext)
  end

  test "the run's agent class builds and persists through the engine's own models" do
    agent, run = build_run

    response = ActionAgent::AgentExecutionService.new(agent, run).send(:generate!)

    assert response, "generate! should return a response from the mock provider"

    # The context was persisted through ActionAgent::AgentContext rather than a
    # top-level AgentContext that only the platform app happens to define.
    assert_operator ActionAgent::AgentContext.count, :>, 0
  end

  test "a full run through the service records no failure" do
    agent, run = build_run

    ActionAgent::AgentExecutionService.call(agent, run)

    assert_nil run.reload.error_message
  end

  test "a provider configured with api_key, as the install generator writes it, can run agents" do
    ActionAgent::ProviderKey.delete_all

    ActiveAgent.stub(:configuration, { openai: { api_key: "sk-host-config" }, anthropic: { access_token: "sk-ant-host" } }) do
      assert_equal %w[openai anthropic], ActionAgent::AgentExecutionService.available_providers(nil)
    end
    ActiveAgent.stub(:configuration, { openai: { api_key: "" } }) do
      assert_empty ActionAgent::AgentExecutionService.available_providers(nil)
    end
  end

  # solid_agent stores a tool row from the provider's own message, which for
  # an OpenAI-format provider carries no tool name. The service knows which
  # tool it ran, and completes the row instead of leaving it anonymous.
  test "a tool row stored without its name is completed from the run's own record" do
    agent, run = build_run
    service = ActionAgent::AgentExecutionService.new(agent, run)
    context = ActionAgent::AgentContext.create!(contextable: agent, agent_name: "A", action_name: "ask")
    row = context.messages.create!(role: "tool", tool_call_id: "call_1", content: '{"count":19}')
    named = context.add_tool_message(tool_call_id: "call_2", tool_name: "kept_name", result: "{}", arguments: { "a" => 1 })
    response = Struct.new(:messages).new([
      Struct.new(:role, :tool_call_id, :content).new("tool", "call_1", '{"count":19}'),
      Struct.new(:role, :tool_call_id, :content).new("tool", "call_2", "{}")
    ])
    service.instance_variable_set(:@tool_invocations, [
      { tool_call_id: "call_1", name: "count_issues", arguments: { "status" => "open" }, duration_ms: 4.2 },
      { tool_call_id: "call_2", name: "other_name", arguments: { "b" => 2 }, duration_ms: 1.0 }
    ])

    service.stub(:conversation_context, context) { service.send(:persist_tool_messages, response) }

    assert_equal 2, context.messages.where(role: "tool").count, "no second row is written for a call already stored"
    assert_equal [ "count_issues", { "status" => "open" }, 4.2 ],
                 [ row.reload.tool_name, row.tool_arguments, row.metadata["duration_ms"] ]
    assert_equal [ "kept_name", { "a" => 1 } ], [ named.reload.tool_name, named.tool_arguments ]
  end
end
