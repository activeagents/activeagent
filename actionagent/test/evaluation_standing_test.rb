# frozen_string_literal: true

require "test_helper"

# Where an evaluation stands against the agent as it is now, and which run
# is its headline.
class ActionAgentEvaluationStandingTest < ActiveSupport::TestCase
  setup do
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
  end

  def build(agent_attributes: {})
    agent = ActionAgent::Agent.create!({ name: "Support", provider: "openai", model: "gpt-4o-mini", instructions: "Help." }.merge(agent_attributes))
    agent.evaluations.create!(name: "Orders", judge_kind: "rules", criteria: [ { "key" => "present", "type" => "response_present", "config" => {} } ])
  end

  def complete_run(evaluation, created_at: Time.current, **attributes)
    evaluation.evaluation_runs.create!({ status: :complete, completed_at: created_at, created_at: created_at, samples_evaluated: 4, samples_passed: 3 }.merge(attributes))
  end

  test "an evaluation with no complete run has none, and one with a run on the agent's latest version is current" do
    evaluation = build
    standing = ActionAgent::EvaluationStanding.new(evaluation)
    assert_equal "none", standing.standing
    assert_nil standing.headline_run

    run = complete_run(evaluation)
    standing = ActionAgent::EvaluationStanding.new(evaluation)
    assert_equal run, standing.headline_run
    assert_equal "current", standing.standing
    assert_equal "current", standing.version_state(run)
    assert standing.counted?
  end

  test "a model-facing edit makes an earlier run stale, an appearance edit does not" do
    evaluation = build
    run = complete_run(evaluation)
    agent = evaluation.agent

    agent.update!(appearance: { "color" => "red" })
    assert_operator agent.agent_versions.count, :>, 1, "an appearance edit still cuts a version"
    assert_equal "current", ActionAgent::EvaluationStanding.new(evaluation.reload).standing

    agent.update!(instructions: "Help, politely.")
    standing = ActionAgent::EvaluationStanding.new(evaluation.reload)
    assert_equal "stale", standing.standing
    assert_equal "earlier", standing.version_state(run.reload)
    assert_not standing.counted?

    complete_run(evaluation)
    assert_equal "current", ActionAgent::EvaluationStanding.new(evaluation.reload).standing
  end

  test "the headline run is the newest complete run; a newer pending or failed run shows beside it" do
    evaluation = build
    finished = complete_run(evaluation, created_at: 2.minutes.ago)
    evaluation.evaluation_runs.create!(status: :pending, created_at: 1.minute.ago)
    evaluation.evaluation_runs.create!(status: :failed, created_at: 30.seconds.ago, completed_at: Time.current)

    standing = ActionAgent::EvaluationStanding.new(evaluation.reload)
    assert_equal finished, standing.headline_run
    assert_equal "current", standing.standing
    assert_equal({ "gpt-4o-mini" => { passed: 3, total: 4 } },
                 ActionAgent::EvaluationStanding.new(evaluation, headline_run: finished.tap { |run| run.scores = { "_models" => { "gpt-4o-mini" => { "scenarios" => 4, "passed" => 3 } } } }).per_model)
  end

  test "an imported run with no release is unrecorded until the agent has a release, then stale; a matching release is current" do
    evaluation = build
    agent = evaluation.agent
    imported = complete_run(evaluation, external_tenant: "", external_run_id: "r1", external_report_digest: "d")
    assert_nil imported.agent_version, "an import does not claim the dashboard's latest version"

    standing = ActionAgent::EvaluationStanding.new(evaluation)
    assert_equal "unrecorded", standing.standing
    assert_equal "unrecorded", standing.version_state(imported)
    assert standing.counted?

    release = agent.find_or_record_release!(digest: "aaaaaaaaaaaa", revision: "deploy-1")
    assert_equal "stale", ActionAgent::EvaluationStanding.new(evaluation.reload).standing, "a release exists that this run did not name"

    released = complete_run(evaluation, external_tenant: "", external_run_id: "r2", external_report_digest: "d", agent_version: release)
    assert_equal "current", ActionAgent::EvaluationStanding.new(evaluation.reload).standing

    agent.record_release!(digest: "bbbbbbbbbbbb", revision: "deploy-2")
    standing = ActionAgent::EvaluationStanding.new(evaluation.reload)
    assert_equal "stale", standing.standing
    assert_equal "earlier", standing.version_state(released.reload)
  end

  test "archived outranks everything, and preload gives a page its standings without a query per evaluation" do
    evaluation = build
    complete_run(evaluation)
    evaluation.archive!
    assert_equal "archived", ActionAgent::EvaluationStanding.new(evaluation).standing
    assert_not ActionAgent::EvaluationStanding.new(evaluation).counted?

    other = build(agent_attributes: { name: "Billing" })
    complete_run(other)
    evaluations = ActionAgent::Evaluation.where(id: [ evaluation.id, other.id ]).includes(:agent, evaluation_runs: :agent_version).to_a

    queries = 0
    counter = ->(_name, _start, _finish, _id, payload) { queries += 1 unless payload[:sql] =~ /SCHEMA|TRANSACTION/i }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      ActionAgent::EvaluationStanding.preload(evaluations)
      assert_equal %w[archived current], evaluations.map { |e| e.standing_info.standing }
    end
    assert_operator queries, :<=, 3
  end
end
