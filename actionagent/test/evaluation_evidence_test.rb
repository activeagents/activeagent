# frozen_string_literal: true

require "test_helper"

class ActionAgentEvaluationEvidenceTest < ActiveSupport::TestCase
  Owner = Struct.new(:id)

  def setup
    @original_scope = ActionAgent.agent_scope_resolver
    ActionAgent.agent_scope_resolver = ->(owner) { owner ? ActionAgent::Agent.where(user_id: owner.id) : ActionAgent::Agent.none }
    @owner = Owner.new(801)
    @other_owner = Owner.new(802)
    @agent = build_agent("Catalog helper", @owner)
    @evaluation = build_evaluation(@agent)
    @scenario = @evaluation.scenarios.create!(key: "catalog_1", prompt: "Show the current catalog.")
    @evidence = ActionAgent::EvaluationEvidence.new(owner: @owner)
  end

  def teardown
    ActionAgent.agent_scope_resolver = @original_scope
  end

  test "all entry points scope their records through the host owner resolver" do
    local = record_result
    other_agent = build_agent("Other helper", @other_owner)
    other_evaluation = build_evaluation(other_agent)
    other_result = record_result(evaluation: other_evaluation,
      scenario: other_evaluation.scenarios.create!(key: "other", prompt: "Other question"))

    assert_equal [ @evaluation.id ], @evidence.list_evaluations[:cards].map { |card| card[:evaluation_id] }
    assert_equal [ local.id ], @evidence.find_demo_candidates[:cards].map { |card| card[:result_id] }
    assert_raises(ActiveRecord::RecordNotFound) { @evidence.list_evaluations(agent_id: other_agent.id) }
    assert_raises(ActiveRecord::RecordNotFound) { @evidence.find_demo_candidates(evaluation_id: other_evaluation.id) }
    assert_raises(ActiveRecord::RecordNotFound) do
      @evidence.read_evaluation_run(evaluation_id: other_evaluation.id, run_id: other_result.evaluation_run_id)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      @evidence.read_evaluation_run(evaluation_id: @evaluation.id, run_id: other_result.evaluation_run_id)
    end
    assert_empty ActionAgent::EvaluationEvidence.new(owner: nil).find_demo_candidates[:cards]
  end

  test "newer failure and infrastructure error suppress earlier passes within their model cohort" do
    record_result(at: 2.hours.ago)
    beta = record_result(model: "beta", at: 2.hours.ago)
    record_result(status: :failed, at: 1.hour.ago)

    assert_equal [ beta.id ], @evidence.find_demo_candidates[:cards].map { |card| card[:result_id] }

    record_result(status: :errored, model: "beta", at: 30.minutes.ago)
    assert_empty @evidence.find_demo_candidates[:cards]
  end

  test "completion order does not make an older attempt override a newer failure" do
    older_pass = record_result(at: 2.hours.ago)
    record_result(status: :failed, at: 1.hour.ago)
    older_pass.update_columns(created_at: Time.current)
    older_pass.evaluation_run.update_columns(completed_at: Time.current)

    assert_empty @evidence.find_demo_candidates[:cards]
  end

  test "cards use the recorded replay prompt and scores after the scenario and rubric change" do
    result = record_result(prompt: "List the two published catalog entries.")
    @scenario.update!(prompt: "A different question", expectations: { "tools" => [ "new_tool" ] })
    @evaluation.update!(criteria: [ { "key" => "new_rule", "type" => "contains", "config" => { "pattern" => "new expectation" } } ])
    @agent.update!(instructions: "New instructions")

    card = @evidence.find_demo_candidates[:cards].sole
    assert_equal "List the two published catalog entries.", card[:recorded_prompt]
    assert_equal({ "response_present" => 1.0 }, card[:recorded_scores])
    assert_equal Digest::SHA256.hexdigest("Original instructions"), card[:instructions_digest]
    assert_equal "historical_pass", card[:evidence_status]
    assert_includes card[:caveats], ActionAgent::EvaluationEvidence::RUBRIC_CAVEAT
    assert_not_includes card.to_json, "A different question"
    assert_not_includes card.to_json, "new expectation"
    assert_equal "/evaluations/#{@evaluation.id}/runs/#{result.evaluation_run_id}/report", card[:path]
    assert_equal "/api/evaluations/#{@evaluation.id}/runs/#{result.evaluation_run_id}/report", card[:report_path]
  end

  test "unlinked and mismatched replay runs cannot supply demo evidence or leak their prompt" do
    missing = record_result(replay: nil)
    foreign_agent = build_agent("Foreign helper", @other_owner)
    foreign_replay = foreign_agent.agent_runs.create!(status: :complete, input_prompt: "Foreign prompt", output: "Foreign output")
    mismatch = record_result(replay: foreign_replay)

    assert_empty @evidence.find_demo_candidates[:cards]
    [ missing, mismatch ].each do |result|
      response = @evidence.read_evaluation_run(evaluation_id: @evaluation.id, run_id: result.evaluation_run_id)
      card = response[:cards].last
      assert_nil card[:recorded_prompt]
      assert_nil card[:agent_run_id]
      assert_equal "recorded_result", card[:evidence_status]
      assert_includes card[:caveats], ActionAgent::EvaluationEvidence::CONTEXT_CAVEAT
      assert_not_includes response.to_json, "Foreign prompt"
      assert_not_includes response.to_json, "Foreign output"
    end
  end

  test "empty output and incomplete linked executions do not qualify as demo candidates" do
    record_result(output: "")
    incomplete = @agent.agent_runs.create!(status: :failed, input_prompt: "An unanswered question")
    record_result(replay: incomplete)

    assert_empty @evidence.find_demo_candidates[:cards]
  end

  test "a failed execution preserves its recorded question without becoming passing evidence" do
    replay = @agent.agent_runs.create!(status: :failed, input_prompt: "Which entries were published today?",
      error_message: "Provider unavailable")
    result = record_result(status: :errored, replay: replay, output: nil)

    assert_empty @evidence.find_demo_candidates[:cards]
    response = @evidence.read_evaluation_run(evaluation_id: @evaluation.id, run_id: result.evaluation_run_id)
    card = response[:cards].last
    assert_equal "Which entries were published today?", card[:recorded_prompt]
    assert_equal "errored", card[:status]
    assert_equal "failed", card[:replay_status]
    assert_equal "recorded_result", card[:evidence_status]
    assert_equal replay.id, card[:agent_run_id]
    assert_not_includes card[:caveats], ActionAgent::EvaluationEvidence::CONTEXT_CAVEAT
    assert_equal card[:path], response[:cards].first[:path]
  end

  test "simulated provider output remains readable but is never a real demo candidate" do
    result = record_result
    result.update!(provider: "mock")

    assert_empty @evidence.find_demo_candidates[:cards]
    response = @evidence.read_evaluation_run(evaluation_id: @evaluation.id, run_id: result.evaluation_run_id)
    assert_equal "recorded_result", response[:cards].last[:evidence_status]
    assert response[:cards].last[:caveats].any? { |caveat| caveat.include?("simulated") }

    result.update!(provider: "openai")
    result.agent_run.update!(output_metadata: { "provider" => "mock" })
    assert_empty @evidence.find_demo_candidates[:cards]
  end

  test "shape checks are disclosed without inferring strength from the current rubric" do
    record_result(scores: { "response_present" => 1.0, "response_length" => 1.0 })
    card = @evidence.find_demo_candidates[:cards].sole
    assert_equal "shape_or_runtime_checks_only", card[:check_strength]
    assert_includes card[:caveats], ActionAgent::EvaluationEvidence::WEAK_CHECK_CAVEAT

    record_result(scores: { "expected_content" => 1.0 })
    card = @evidence.find_demo_candidates[:cards].sole
    assert_equal "expectation_scores_recorded", card[:check_strength]
    assert_includes card[:caveats], ActionAgent::EvaluationEvidence::RUBRIC_CAVEAT

    record_result(scores: { "custom_quality" => 1.0 })
    assert_equal "unknown_rubric", @evidence.find_demo_candidates[:cards].sole[:check_strength]
  end

  test "search is bounded and announces incomplete coverage instead of finding an older pass beyond the bound" do
    old = record_result(at: 2.hours.ago)
    limit = ActionAgent::EvaluationEvidence::MAX_SCAN_RESULTS
    run = @evaluation.evaluation_runs.create!(status: :complete, created_at: 1.hour.ago)
    attributes = limit.times.map do |index|
      {
        evaluation_run_id: run.id, evaluation_scenario_id: @scenario.id,
        provider: "openai", model: "failed-model-#{index}", status: 2,
        created_at: 1.hour.ago, updated_at: 1.hour.ago
      }
    end
    ActionAgent::EvaluationScenarioResult.insert_all!(attributes)

    response = @evidence.find_demo_candidates(limit: 1_000_000)
    assert_empty response[:cards]
    assert_equal limit, response[:coverage][:scanned]
    assert_equal ActionAgent::EvaluationEvidence::MAX_CANDIDATES, response[:coverage][:limit]
    assert response[:coverage][:truncated]
    assert_not_includes response.to_json, old.output
  end

  test "report reading bounds results and text while preserving failed result evidence" do
    result = record_result(prompt: "p" * 2000, output: "o" * 2000, status: :failed)
    run = result.evaluation_run
    20.times do
      run.scenario_results.create!(evaluation_scenario_id: @scenario.id, provider: "openai", model: "other",
        status: :failed, output: "short", error_message: "A recorded failure")
    end

    response = @evidence.read_evaluation_run(evaluation_id: @evaluation.id, run_id: run.id)
    assert_equal 21, response[:cards].size
    assert response[:coverage][:truncated]
    card = response[:cards][1]
    assert_equal "failed", card[:status]
    assert_equal 1200, card[:recorded_prompt].length
    assert_equal 1200, card[:output_excerpt].length
    assert card[:prompt_truncated]
    assert card[:output_truncated]
    assert_equal "recorded_result", card[:evidence_status]
    assert_kind_of Hash, JSON.parse(response.to_json)
  end

  test "bounded report evidence puts late errors and failures before earlier successful cases" do
    result = record_result
    run = result.evaluation_run
    20.times do
      run.scenario_results.create!(scenario: @scenario, provider: "openai", model: "alpha", status: :passed, output: "A successful answer")
    end
    failure = run.scenario_results.create!(scenario: @scenario, provider: "openai", model: "alpha", status: :failed,
      output: "An answer without the expected content", fault: "missing_content")
    error = run.scenario_results.create!(scenario: @scenario, provider: "openai", model: "alpha", status: :errored,
      error_message: "Provider unavailable", fault: "run_error")
    pending = run.scenario_results.create!(scenario: @scenario, provider: "openai", model: "alpha", status: :pending)

    response = @evidence.read_evaluation_run(evaluation_id: @evaluation.id, run_id: run.id)
    cards = response[:cards].drop(1)
    assert_equal [ error.id, failure.id, pending.id ], cards.first(3).map { |card| card[:result_id] }
    assert_equal %w[errored failed pending passed], cards.first(4).map { |card| card[:status] }
    assert_equal ActionAgent::EvaluationEvidence::REDACTED_ERROR, cards.first[:error]
    assert_equal "failures_first", response[:coverage][:selection]
    assert_equal({ "passed" => 21, "failed" => 1, "errored" => 1, "pending" => 1 }, response[:coverage][:recorded_status_counts])
    assert response[:coverage][:truncated]
    assert_equal ActionAgent::EvaluationEvidence::MAX_REPORT_RESULTS, cards.size
  end

  test "evaluation search escapes wildcards and limits results before reading latest runs" do
    record_result(at: 2.hours.ago)
    latest = record_result(at: 1.hour.ago)
    other = build_evaluation(@agent, name: "100% literal")

    assert_equal [ other.id ], @evidence.list_evaluations(query: "%")[:cards].map { |card| card[:evaluation_id] }
    response = @evidence.list_evaluations(limit: 1)
    assert_equal 1, response[:cards].size
    assert response[:coverage][:truncated]
    result = @evidence.list_evaluations(query: "catalog")[:cards].sole
    assert_equal latest.evaluation_run_id, result[:latest_run][:run_id]
    assert_equal "/evaluations/#{@evaluation.id}/runs/#{latest.evaluation_run_id}/report", result[:latest_run][:path]
  end

  private

  def build_agent(name, owner)
    ActionAgent::Agent.create!(name: name, user_id: owner.id, provider: "openai", model: "alpha", instructions: "Original instructions")
  end

  def build_evaluation(agent, name: "Catalog evaluation")
    agent.evaluations.create!(name: name, judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ])
  end

  def record_result(evaluation: @evaluation, scenario: @scenario, status: :passed, model: "alpha", at: Time.current,
    prompt: "List the published catalog entries.", output: "The catalog includes two published entries.",
    replay: :create, scores: { "response_present" => 1.0 })
    run = evaluation.evaluation_runs.create!(status: :complete, created_at: at, completed_at: at + 1.minute,
      samples_evaluated: 1, samples_passed: status == :passed ? 1 : 0)
    if replay == :create
      replay = evaluation.agent.agent_runs.create!(status: :complete, input_prompt: prompt, output: output,
        output_metadata: { "instructions" => "Original instructions", "provider" => "openai", "model" => model })
    end
    run.scenario_results.create!(scenario: scenario, agent_run: replay, provider: "openai", model: model, status: status,
      output: output, scores: scores, score: status == :passed ? 1.0 : 0.0, created_at: at)
  end
end
