# frozen_string_literal: true

require "test_helper"

# Replays a scenario suite through the mock provider (test environment only)
# and through stubbed runs, and checks the scores, per-model summaries,
# recommendations and verdict the runner writes.
class ActionAgentScenarioEvaluationRunnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    ActionAgent::Agent.delete_all
  end

  def build_suite(**attributes)
    agent = ActionAgent::Agent.create!(
      { name: "Suite Agent", provider: "mock", model: "mock-model", instructions: "Answer with the data." }.merge(attributes)
    )
    evaluation = agent.evaluations.new(
      name: "Question catalog",
      judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    evaluation.scenarios.build(key: "find_1", group: "Find", prompt: "Which gynecologists in Charlotte have scheduling enabled?")
    evaluation.scenarios.build(key: "find_2", group: "Find", prompt: "Show me all providers with no license on file",
      expectations: { "tools" => [ "find_records" ] })
    evaluation.scenarios.build(key: "blame_1", group: "Blame", prompt: "Who changed the biography for Dr. AbdelRazek?")
    evaluation.save!
    evaluation
  end

  test "every enabled scenario is replayed once per model and written as a result" do
    evaluation = build_suite

    run = evaluation.run!(models: [ "mock/alpha", "mock/beta" ])

    assert_equal "complete", run.status
    assert_equal 6, run.scenario_results.count
    assert_equal %w[alpha beta], run.scenario_results.distinct.pluck(:model).sort
    assert_equal 6, run.samples_evaluated
    assert run.scenario_results.all? { |result| result.agent_run.present? }, "each result links its replay run"
  end

  test "a selection narrows the run to one group and records what it covered" do
    evaluation = build_suite

    run = evaluation.run!(group: "Blame")

    assert_equal [ "blame_1" ], run.scenario_results.map { |result| result.scenario.key }
    assert_equal [ "blame_1" ], run.selection["scenario_keys"]
    assert_equal "Blame", run.selection["group"]
    assert_equal [ "mock-model" ], run.models
  end

  test "keys and scenario_ids select individual scenarios" do
    evaluation = build_suite
    find_two = evaluation.scenarios.find_by!(key: "find_2")

    by_key = evaluation.run!(keys: [ "find_1" ])
    by_id = evaluation.run!(scenario_ids: [ find_two.id ])

    assert_equal [ "find_1" ], by_key.scenario_results.map { |result| result.scenario.key }
    assert_equal [ "find_2" ], by_id.scenario_results.map { |result| result.scenario.key }
  end

  test "an empty selection fails the run rather than silently running nothing" do
    evaluation = build_suite

    run = evaluation.run!(group: "Nope")

    assert_equal "failed", run.status
    assert_match(/No scenarios selected/, run.error_message)
  end

  test "a disabled scenario is skipped" do
    evaluation = build_suite
    evaluation.scenarios.find_by!(key: "find_1").update!(enabled: false)

    run = evaluation.run!

    assert_equal %w[blame_1 find_2], run.scenario_results.map { |result| result.scenario.key }.sort
  end

  test "comparison scores are cohort maps and the summary ranks models by pass rate" do
    evaluation = build_suite

    run = evaluation.run!(models: [ "mock/alpha", "mock/beta" ])
    scores = run.scores

    assert_equal %w[mock/alpha mock/beta], scores["response_present"].keys.sort
    assert_equal %w[mock/alpha mock/beta], scores["_models"].keys.sort
    summary = scores["_models"]["mock/alpha"]
    assert_equal 3, summary["scenarios"]
    assert_equal "mock", summary["provider"]
    assert_equal "alpha", summary["model"]
    assert_kind_of Numeric, summary["pass_rate"]
    assert scores["_verdict"]["winner"].present?
    assert_equal "pass rate", scores["_verdict"]["judge"]
    assert_equal run.selection, scores["_selection"]
  end

  test "an expected tool the agent never calls is diagnosed and rolled up into recommendations" do
    evaluation = build_suite

    run = evaluation.run!(keys: [ "find_2" ])
    result = run.scenario_results.first

    assert_equal "failed", result.status
    assert_equal "expected_tool_not_called", result.fault
    assert_equal 0.0, result.scores["expected_tools"]
    assert_match(/find_records/, result.recommendation)

    recommendation = run.scores["_recommendations"].first
    assert_equal "expected_tool_not_called", recommendation["fault"]
    assert_equal [ "find_2" ], recommendation["scenario_keys"]
    assert_equal 1, recommendation["count"]
    assert_equal({ "expected_tool_not_called" => 1 }, run.scores["_models"]["mock-model"]["faults"])
  end

  test "a scenario the mock provider answers passes when nothing is expected of the answer" do
    evaluation = build_suite

    run = evaluation.run!(keys: [ "find_1" ])
    result = run.scenario_results.first

    assert_equal "passed", result.status
    assert_nil result.fault
    assert_equal 1.0, result.score
    assert_equal 1, run.samples_passed
  end

  test "a failed replay is an errored result with a run_error fault, and the run still completes" do
    evaluation = build_suite(provider: "anthropic", model: "claude-sonnet-5")

    run = evaluation.run!(keys: [ "find_1" ])
    result = run.scenario_results.first

    assert_equal "complete", run.status
    assert_equal "errored", result.status
    assert_equal "run_error", result.fault
    assert_match(/credentials/i, result.error_message)
    assert_equal 1, run.scores["_models"]["claude-sonnet-5"]["errored"]
  end

  test "tool calls are rebuilt from the replay's progress events" do
    evaluation = build_suite
    agent = evaluation.agent
    fake_run = agent.agent_runs.create!(
      status: :complete, trace_id: SecureRandom.uuid, input_prompt: "x", output: "Found 3 providers.",
      duration_ms: 120, input_tokens: 10, output_tokens: 5,
      logs: [
        { "eid" => "1-1", "kind" => "tool", "label" => "find_records", "status" => "started", "detail" => { "model" => "Physician" }.to_json },
        { "eid" => "1-1", "kind" => "tool", "label" => "find_records", "status" => "done", "duration_ms" => 40, "detail" => "3 rows" }
      ]
    )
    agent.define_singleton_method(:test_execute) { |*, **| fake_run }

    run = evaluation.run!(keys: [ "find_2" ])
    result = run.scenario_results.first

    assert_equal "passed", result.status
    assert_equal [ { "name" => "find_records", "arguments" => { "model" => "Physician" }, "error" => false, "detail" => "3 rows", "duration_ms" => 40 } ],
      result.tool_calls
    assert_equal 1.0, result.scores["expected_tools"]
    assert_equal 1.0, result.scores["tools_succeeded"]
    assert_in_delta 0.000045, result.cost.to_f, 0.0001
  end

  test "an evaluation with scenarios runs through the scenario runner and one without through the sampler" do
    evaluation = build_suite
    plain = evaluation.agent.evaluations.create!(
      name: "Plain", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )

    assert evaluation.scenario_suite?
    assert_not plain.scenario_suite?
    assert_equal "failed", plain.run!.status, "no recorded generations to sample yet"
  end

  test "run_later! creates a pending run that the job completes" do
    evaluation = build_suite

    run = evaluation.run_later!(group: "Blame")
    assert_equal "pending", run.status

    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)

    assert_equal "complete", run.reload.status
    assert_equal [ "blame_1" ], run.scenario_results.map { |result| result.scenario.key }
  end

  test "replace_scenarios! keeps the records whose keys survive" do
    evaluation = build_suite
    original = evaluation.scenarios.find_by!(key: "find_1")

    evaluation.replace_scenarios!(ActiveAgents::Evals::ScenarioParser.parse("# Find\nA rewritten first question\n# Search\nWhy is this provider not showing?"))

    assert_equal %w[find_1 search_1], evaluation.scenarios.ordered.map(&:key)
    assert_equal original.id, evaluation.scenarios.find_by!(key: "find_1").id
    assert_equal "A rewritten first question", original.reload.prompt
  end
end
