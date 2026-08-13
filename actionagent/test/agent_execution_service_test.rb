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
end
