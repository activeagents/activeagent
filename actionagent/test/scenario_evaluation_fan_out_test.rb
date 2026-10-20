# frozen_string_literal: true

require "test_helper"

# A fanned-out scenario evaluation (ActionAgent.scenario_evaluation_fan_out):
# one EvaluationReplayJob per scenario x model, one EvaluationJudgeJob per
# stored replay, and the last scored result completing the run with the
# scores the sequential path writes.
class ActionAgentScenarioEvaluationFanOutTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def setup
    ActionAgent::Agent.delete_all
    @fan_out = ActionAgent.scenario_evaluation_fan_out
    ActionAgent.scenario_evaluation_fan_out = true
  end

  def teardown
    ActionAgent.scenario_evaluation_fan_out = @fan_out
    super
  end

  def build_suite
    agent = ActionAgent::Agent.create!(name: "Suite Agent", provider: "mock", model: "mock-model", instructions: "Answer with the data.")
    evaluation = agent.evaluations.new(
      name: "Support questions",
      judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    evaluation.scenarios.build(key: "tickets_1", group: "Tickets", prompt: "Which open tickets mention a refund?")
    evaluation.scenarios.build(key: "tickets_2", group: "Tickets", prompt: "Show me all tickets with no assignee",
      expectations: { "tools" => [ "find_tickets" ] })
    evaluation.scenarios.build(key: "history_1", group: "History", prompt: "Who changed the shipping policy last week?")
    evaluation.save!
    evaluation
  end

  # Performs enqueued jobs, and the jobs they enqueue, until none are left.
  def drain(only: nil)
    loop do
      pending = enqueued_jobs.select { |job| only.nil? || Array(only).map(&:name).include?(job["job_class"]) }
      break if pending.empty?

      perform_enqueued_jobs(only: only)
    end
  end

  def run_fanned_out(evaluation, **selection)
    run = evaluation.run_later!(**selection)
    drain
    run.reload
  end

  # Replaces the judge every ScenarioEvaluationRunner asks, since each job
  # builds its own runner.
  def with_judge(judge)
    klass = ActionAgent::ScenarioEvaluationRunner
    originals = %i[judge_provider judge_class].to_h { |name| [ name, klass.instance_method(name) ] }
    klass.define_method(:judge_provider) { :anthropic }
    klass.define_method(:judge_class) { judge }
    yield
  ensure
    originals.each { |name, method| klass.define_method(name, method) }
  end

  def fake_judge(prompts = [])
    reply = Struct.new(:content, :input_tokens, :output_tokens, :model) do
      def message = Struct.new(:content).new(content)
      def usage = Struct.new(:input_tokens, :output_tokens).new(input_tokens, output_tokens)
      def generate_now = self
    end
    Class.new do
      define_singleton_method(:prompt) do |message:, instructions:|
        content = if instructions.include?("comparing model cohorts")
          prompts << :verdict
          { winner: "mock/alpha", rationale: "Marginally better." }.to_json
        elsif instructions.include?("recommend the fix")
          prompts << :recommend
          { recommendation: "Enable find_tickets.", suggested_tool: nil, instruction_change: nil }.to_json
        else
          prompts << :score
          { score: 0.9 }.to_json
        end
        reply.new(content, 200, 10, "claude-opus-5")
      end
    end
  end

  test "the run job enqueues one replay per scenario x model and returns the run still running" do
    run = build_suite.run_later!(models: [ "mock/alpha", "mock/beta" ])

    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)

    assert_equal "running", run.reload.status
    assert_equal 6, enqueued_jobs.count { |job| job["job_class"] == "ActionAgent::EvaluationReplayJob" }
    assert_equal 0, run.scenario_results.count
  end

  test "replays are stored pending and scored by their own jobs, the last of which completes the run" do
    run = build_suite.run_later!(models: [ "mock/alpha", "mock/beta" ])
    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)

    perform_enqueued_jobs(only: ActionAgent::EvaluationReplayJob)

    assert_equal "running", run.reload.status
    assert_equal 6, run.scenario_results.pending.count
    assert run.scenario_results.all? { |result| result.agent_run.present? }, "each pending result links its replay run"
    assert_equal 6, enqueued_jobs.count { |job| job["job_class"] == "ActionAgent::EvaluationJudgeJob" }

    perform_enqueued_jobs(only: ActionAgent::EvaluationJudgeJob)

    assert_equal "complete", run.reload.status
    assert_equal 0, run.scenario_results.pending.count
    assert_equal 6, run.samples_evaluated
    assert_nil run.scores["_fan_out"], "the bookkeeping is replaced by the run's scores"
  end

  test "a fanned-out run writes the results and scores the sequential path writes" do
    fanned = run_fanned_out(build_suite, models: [ "mock/alpha", "mock/beta" ])
    ActionAgent.scenario_evaluation_fan_out = false
    sequential = build_suite.run!(models: [ "mock/alpha", "mock/beta" ])

    rows = ->(run) { run.scenario_results.includes(:scenario).map { |row| [ row.scenario.key, row.model, row.status, row.fault, row.score ] }.sort_by(&:to_s) }
    assert_equal rows.call(sequential), rows.call(fanned)
    assert_equal sequential.samples_passed, fanned.samples_passed
    assert_equal sequential.scores.keys.sort, fanned.scores.keys.sort
    %w[response_present _recommendations _verdict].each do |key|
      assert_equal sequential.scores[key], fanned.scores[key], key
    end
    comparable = ->(summary) { summary.transform_values { |model| model.except("avg_duration_ms") } }
    assert_equal comparable.call(sequential.scores["_models"]), comparable.call(fanned.scores["_models"])
  end

  test "a retried replay job does not replay the pair again" do
    evaluation = build_suite
    run = evaluation.run_later!(keys: [ "tickets_1" ])
    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)
    job = enqueued_jobs.find { |entry| entry["job_class"] == "ActionAgent::EvaluationReplayJob" }
    args = ActiveJob::Arguments.deserialize(job["arguments"])

    2.times { ActionAgent::EvaluationReplayJob.perform_now(*args) }

    assert_equal 1, run.scenario_results.count
    assert_equal 1, evaluation.agent.agent_runs.count
  end

  test "the judge's spend is metered once across the jobs, with the verdict as the run's own" do
    prompts = []
    evaluation = build_suite
    evaluation.update!(judge_kind: "llm", judge_model: "claude-opus-5",
      criteria: [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is the answer useful?" } } ])

    run = with_judge(fake_judge(prompts)) { run_fanned_out(evaluation, keys: %w[tickets_1 tickets_2], models: [ "mock/alpha", "mock/beta" ]) }

    assert_equal "complete", run.status
    usage = run.scores["_judge_usage"]
    assert_equal prompts.size, usage["calls"], "every judge call is counted exactly once"
    assert_equal prompts.tally.transform_keys(&:to_s), usage["by_kind"]
    assert_equal 4, usage.dig("by_kind", "score")
    assert_equal 1, usage.dig("by_kind", "verdict")
    assert_equal 200 * usage["calls"], usage["input_tokens"]
    assert_equal "mock/alpha", run.scores.dig("_verdict", "winner")
    assert_equal 4, run.usage[:replays]
  end

  test "recommendations share one run-wide limit across the jobs" do
    prompts = []
    evaluation = build_suite
    evaluation.update!(judge_kind: "llm", judge_model: "claude-opus-5",
      criteria: [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is the answer useful?" } } ])
    run = evaluation.run_later!(keys: [ "tickets_2" ], models: [ "mock/alpha", "mock/beta" ])
    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)
    run.reload.update!(scores: { "_fan_out" => { "refinements" => ActiveAgent::Evals::Runner::DEFAULT_JUDGE_LIMIT } })

    with_judge(fake_judge(prompts)) { drain }

    assert_equal "complete", run.reload.status
    assert_not_includes prompts, :recommend, "the limit was already spent"
    assert run.scenario_results.all? { |result| result.fault == "expected_tool_not_called" }
  end

  test "a result whose scoring fails is stored errored and the run still completes" do
    run = build_suite.run_later!(keys: [ "tickets_1" ])
    drain(only: [ ActionAgent::EvaluationRunJob, ActionAgent::EvaluationReplayJob ])
    klass = ActionAgent::ScenarioEvaluationRunner
    original = klass.instance_method(:judge_result!)
    klass.define_method(:judge_result!) { |_row| raise "judge exploded" }

    perform_enqueued_jobs(only: ActionAgent::EvaluationJudgeJob)

    result = run.scenario_results.first
    assert_equal "errored", result.status
    assert_match(/judge exploded/, result.error_message)
    assert_equal "complete", run.reload.status
  ensure
    klass&.define_method(:judge_result!, original) if original
  end

  test "a run a host adapter replays stays one sequential job" do
    calls = 0
    adapter = lambda do |scenarios:, models:, on_result:, **|
      calls += 1
      results = scenarios.product(models).map do |scenario, spec|
        replay = ActiveAgent::Evals::Replay.new(answer: "ok", metadata: {})
        ActiveAgent::Evals::Result.new(scenario: scenario, spec: spec, replay: replay, scores: {}, score: 1.0, status: "passed")
          .tap { |result| on_result.call(result) }
      end
      ActiveAgent::Evals::Report.new(results: results, models: models)
    end
    previous = ActionAgent.scenario_evaluation_adapter_resolver
    ActionAgent.scenario_evaluation_adapter_resolver = ->(_evaluation) { adapter }

    run = build_suite.run_later!(keys: [ "tickets_1" ])
    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)

    assert_equal 1, calls
    assert_equal "complete", run.reload.status
    assert_empty enqueued_jobs.select { |job| job["job_class"] == "ActionAgent::EvaluationReplayJob" }
  ensure
    ActionAgent.scenario_evaluation_adapter_resolver = previous
  end

  test "with fan-out off a run is still one sequential job" do
    ActionAgent.scenario_evaluation_fan_out = false
    run = build_suite.run_later!(keys: [ "tickets_1" ])

    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)

    assert_equal "complete", run.reload.status
    assert_empty enqueued_jobs.select { |job| job["job_class"] == "ActionAgent::EvaluationReplayJob" }
  end
end
