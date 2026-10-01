# frozen_string_literal: true

require "test_helper"

# The agent card's evaluation tile: the pass rate pooled over the headline
# runs of the agent's evaluations that stand against its current version.
class ActionAgentAgentScorecardTest < ActiveSupport::TestCase
  setup do
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
  end

  def evaluation(agent, name)
    agent.evaluations.create!(name: name, judge_kind: "rules", criteria: [ { "key" => "present", "type" => "response_present", "config" => {} } ])
  end

  def complete_run(evaluation, passed:, total:, created_at: Time.current, **attributes)
    evaluation.evaluation_runs.create!({ status: :complete, completed_at: created_at, created_at: created_at,
                                         samples_evaluated: total, samples_passed: passed,
                                         scores: { "present" => { "score" => 0.5, "passed" => passed, "total" => total } } }.merge(attributes))
  end

  test "the tile pools current and unrecorded headline runs and leaves out stale and archived evaluations" do
    agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini", instructions: "Help.")
    stale = evaluation(agent, "Old suite")
    complete_run(stale, passed: 0, total: 10, created_at: 3.minutes.ago)
    agent.update!(instructions: "Help, politely.")

    current = evaluation(agent, "Orders")
    complete_run(current, passed: 2, total: 6, created_at: 2.minutes.ago)
    complete_run(current, passed: 5, total: 6, created_at: 1.minute.ago)
    current.evaluation_runs.create!(status: :pending)

    unrecorded = evaluation(agent, "Published")
    complete_run(unrecorded, passed: 3, total: 4, external_tenant: "", external_run_id: "r1", external_report_digest: "d")

    archived = evaluation(agent, "Retired")
    complete_run(archived, passed: 4, total: 4)
    archived.archive!

    stats = ActionAgent::AgentScorecard.for_agents([ agent ])[agent.id]
    assert_equal 8, stats[:eval_samples_passed]
    assert_equal 10, stats[:eval_samples_evaluated]
    assert_in_delta 0.8, stats[:eval_score], 1e-9, "the pooled pass rate, not a mean criterion score"
    assert_equal 2, stats[:eval_runs]
    assert_equal 2, stats[:eval_not_counted]
  end

  test "an agent with nothing to count has no evaluation score" do
    agent = ActionAgent::Agent.create!(name: "Quiet", provider: "openai", model: "gpt-4o-mini")
    evaluation(agent, "Empty").evaluation_runs.create!(status: :failed, completed_at: Time.current)

    stats = ActionAgent::AgentScorecard.for_agents([ agent ])[agent.id]
    assert_nil stats[:eval_score]
    assert_equal 0, stats[:eval_samples_evaluated]
  end
end
