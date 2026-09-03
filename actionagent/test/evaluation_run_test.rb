# frozen_string_literal: true

require "test_helper"

# EvaluationRun#average_score reads a scores payload that is not uniformly
# { criterion => stats }: a comparison run writes "_"-prefixed metadata and
# cohort maps of model => stats alongside plain criterion hashes.
class ActionAgentEvaluationRunTest < ActiveSupport::TestCase
  def run_with(scores)
    ActionAgent::EvaluationRun.new(scores: scores)
  end

  test "plain criterion stats are averaged" do
    run = run_with(
      "response_present" => { "score" => 1.0, "min" => 1.0, "max" => 1.0, "passed" => 2, "total" => 2 },
      "latency" => { "score" => 0.5, "min" => 0.5, "max" => 0.5, "passed" => 0, "total" => 2 }
    )

    assert_in_delta 0.75, run.average_score, 0.0001
  end

  test "skipped criteria carry no score and drop out of the average" do
    run = run_with(
      "llm_judge" => { "skipped" => true, "reason" => "No judge provider configured" },
      "latency" => { "score" => 0.4, "min" => 0.4, "max" => 0.4, "passed" => 0, "total" => 1 }
    )

    assert_in_delta 0.4, run.average_score, 0.0001
  end

  # Regression: EvaluationRunnerService#score_comparison writes
  # scores["_missing_models"] = ["gpt-4o"] (an Array) for a comparison run
  # whose cohorts have no generations. average_score used to call
  # Array#[]("score"), raising TypeError and permanently 500-ing
  # GET <mount>/api/evaluations.
  test "_missing_models does not raise and is excluded from the average" do
    run = run_with(
      "response_present" => { "score" => 0.8, "min" => 0.8, "max" => 0.8, "passed" => 1, "total" => 1 },
      "_missing_models" => [ "gpt-4o" ]
    )

    assert_nothing_raised { run.average_score }
    assert_in_delta 0.8, run.average_score, 0.0001
  end

  test "underscore metadata alone averages to nil rather than raising" do
    run = run_with("_missing_models" => [ "gpt-4o", "no-such-model" ])

    assert_nil run.average_score
  end

  test "a comparison cohort map averages its per-model scores" do
    run = run_with(
      "response_present" => {
        "gpt-4o-mini" => { "score" => 1.0, "min" => 1.0, "max" => 1.0, "passed" => 2, "total" => 2 },
        "claude-haiku" => { "score" => 0.6, "min" => 0.6, "max" => 0.6, "passed" => 1, "total" => 2 }
      }
    )

    assert_in_delta 0.8, run.average_score, 0.0001
  end

  test "a comparison run averages cohort maps alongside metadata and a verdict" do
    run = run_with(
      "response_present" => {
        "gpt-4o-mini" => { "score" => 1.0, "total" => 2 },
        "claude-haiku" => { "score" => 0.6, "total" => 2 }
      },
      "latency" => {
        "gpt-4o-mini" => { "score" => 0.4, "total" => 2 },
        "claude-haiku" => { "score" => 0.8, "total" => 2 }
      },
      "_missing_models" => [ "no-such-model" ],
      "_verdict" => { "winner" => "gpt-4o-mini", "rationale" => "Fewer empty answers." }
    )

    # (1.0 + 0.6) / 2 = 0.8 and (0.4 + 0.8) / 2 = 0.6, averaged => 0.7
    assert_in_delta 0.7, run.average_score, 0.0001
  end

  test "a cohort whose models were all skipped contributes no score" do
    run = run_with(
      "llm_judge" => {
        "gpt-4o-mini" => { "skipped" => true, "reason" => "No judge provider configured" },
        "claude-haiku" => { "skipped" => true, "reason" => "No judge provider configured" }
      },
      "latency" => { "score" => 0.9, "total" => 1 }
    )

    assert_in_delta 0.9, run.average_score, 0.0001
  end

  test "an empty scores payload averages to nil" do
    assert_nil run_with({}).average_score
  end
end

# The Evaluations index serializes the latest run of every listed evaluation,
# so a single unaveragable run used to take the whole page down.
class ActionAgentEvaluationsIndexTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
  end

  test "the index survives a comparison run that records _missing_models" do
    agent = ActionAgent::Agent.create!(name: "Comparer", provider: "openai", model: "gpt-4o-mini")
    evaluation = agent.evaluations.create!(
      name: "Model bake-off",
      judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ],
      config: { "compare_models" => [ "gpt-4o-mini", "no-such-model" ] }
    )
    evaluation.evaluation_runs.create!(
      status: :complete,
      scores: {
        "response_present" => {
          "gpt-4o-mini" => { "score" => 1.0, "min" => 1.0, "max" => 1.0, "passed" => 2, "total" => 2 }
        },
        "_missing_models" => [ "no-such-model" ]
      },
      samples_evaluated: 2,
      samples_passed: 2,
      completed_at: Time.current
    )

    get "/activeagents/api/evaluations"

    assert_response :success
    body = JSON.parse(response.body)
    latest = body["evaluations"].first["latest_run"]
    assert_in_delta 1.0, latest["average_score"], 0.0001
    assert_equal [ "no-such-model" ], latest.dig("scores", "_missing_models")
  end
end
