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

  # +on_call+ is told the kind of each call (:score, :recommend, :verdict)
  # as it is made.
  def fake_judge(prompts = [], on_call: nil)
    reply = Struct.new(:content, :input_tokens, :output_tokens, :model) do
      def message = Struct.new(:content).new(content)
      def usage = Struct.new(:input_tokens, :output_tokens).new(input_tokens, output_tokens)
      def generate_now = self
    end
    Class.new do
      define_singleton_method(:prompt) do |message:, instructions:|
        kind, content = if instructions.include?("comparing model cohorts")
          [ :verdict, { winner: "mock/alpha", rationale: "Marginally better." }.to_json ]
        elsif instructions.include?("recommend the fix")
          [ :recommend, { recommendation: "Enable find_tickets.", suggested_tool: nil, instruction_change: nil }.to_json ]
        else
          [ :score, { score: 0.9 }.to_json ]
        end
        prompts << kind
        on_call&.call(kind)
        reply.new(content, 200, 10, "claude-opus-5")
      end
    end
  end

  # Runs the block with +method_name+ of +klass+ replaced by +body+ (a proc,
  # evaluated on the instance), and the original restored after it.
  def with_method(klass, method_name, body)
    original = klass.instance_method(method_name)
    klass.define_method(method_name, &body)
    yield
  ensure
    klass.define_method(method_name, original)
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
    comparable = ->(summary) { summary.transform_values { |model| model.reject { |key, _| key.end_with?("_duration_ms") } } }
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
    assert_equal usage["calls"], run.to_report.judge_usage["calls"], "the rebuilt report counts each judge call once"
    assert_equal usage["cost"], run.to_report.judge_usage["cost"]
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

  test "the judge is asked with no lock held on the run" do
    prompts = []
    under_lock = []
    evaluation = build_suite
    evaluation.update!(judge_kind: "llm", judge_model: "claude-opus-5",
      criteria: [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is the answer useful?" } } ])
    judge = fake_judge(prompts, on_call: ->(kind) { under_lock << kind if Thread.current[:evaluation_run_locked] })
    lock = ActionAgent::EvaluationRun.instance_method(:with_lock)

    marked = proc do |*args, &block|
      lock.bind_call(self, *args) do
        Thread.current[:evaluation_run_locked] = true
        block.call
      ensure
        Thread.current[:evaluation_run_locked] = false
      end
    end
    run = with_method(ActionAgent::EvaluationRun, :with_lock, marked) do
      with_judge(judge) { run_fanned_out(evaluation, keys: %w[tickets_1 tickets_2], models: [ "mock/alpha", "mock/beta" ]) }
    end

    assert_equal "complete", run.status
    assert_includes prompts, :verdict
    assert_empty under_lock, "a judge call under the run's lock stalls every other writer on SQLite"
  end

  test "a scenario removed during the run is left out, and the run still completes" do
    evaluation = build_suite
    run = evaluation.run_later!(models: [ "mock/alpha" ])
    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)
    # Removed before its replay job runs.
    evaluation.scenarios.find_by!(key: "history_1").destroy!

    perform_enqueued_jobs(only: ActionAgent::EvaluationReplayJob)
    assert_equal 2, run.scenario_results.pending.count
    # Removed after its replay was stored and its judge job enqueued: the
    # result goes with it, and the judge job finds nothing to score.
    evaluation.scenarios.find_by!(key: "tickets_2").destroy!

    drain

    assert_equal "complete", run.reload.status
    assert_equal [ "tickets_1" ], run.scenario_results.includes(:scenario).map { |row| row.scenario.key }
    assert_equal 1, run.samples_evaluated
    assert_nil run.scores["_fan_out"]
  end

  test "a run whose every scenario was removed fails rather than waiting forever" do
    evaluation = build_suite
    run = evaluation.run_later!(keys: [ "tickets_1" ])
    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)
    evaluation.scenarios.find_by!(key: "tickets_1").destroy!

    drain

    assert_equal "failed", run.reload.status
    assert_match(/removed during the run/, run.error_message)
  end

  test "a judge job delivered again for a result already scored still completes the run" do
    run = build_suite.run_later!(keys: [ "tickets_1" ])
    drain(only: [ ActionAgent::EvaluationRunJob, ActionAgent::EvaluationReplayJob ])
    row = run.scenario_results.sole

    # The worker stops after the result is stored, before the run is completed.
    with_method(ActionAgent::ScenarioEvaluationRunner, :finish_fan_out!, proc { |_run| nil }) do
      perform_enqueued_jobs(only: ActionAgent::EvaluationJudgeJob)
    end
    assert_equal "passed", row.reload.status
    assert_equal "running", run.reload.status

    ActionAgent::EvaluationJudgeJob.perform_now(row.id, {}, run.id)

    assert_equal "complete", run.reload.status
  end

  test "of two judge jobs delivered for one result, only the one whose claim lands scores it" do
    prompts = []
    evaluation = build_suite
    evaluation.update!(judge_kind: "llm", judge_model: "claude-opus-5",
      criteria: [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is the answer useful?" } } ])
    run = evaluation.run_later!(keys: [ "tickets_1" ])
    drain(only: [ ActionAgent::EvaluationRunJob, ActionAgent::EvaluationReplayJob ])
    row = run.scenario_results.sole
    delivery = ActionAgent::EvaluationScenarioResult.find(row.id)
    # The other delivery's claim landed first.
    ActionAgent::EvaluationScenarioResult.where(id: row.id).update_all(updated_at: 1.second.from_now)

    with_judge(fake_judge(prompts)) { ActionAgent::ScenarioEvaluationRunner.new(evaluation, run: run).judge_result!(delivery) }

    assert_empty prompts, "the judge is asked once per result"
    assert_equal "pending", row.reload.status
    assert_equal "running", run.reload.status
  end

  test "the agent's tools are discovered once for the run, not once per job" do
    discoveries = 0
    warnings = []
    original = ActionAgent::MCPToolDispatcher.instance_method(:tool_definitions)

    counted = proc { |*args| discoveries += 1; original.bind_call(self, *args) }
    warned = proc { warnings << "discovery warning #{warnings.size + 1}"; warnings.last }
    run = with_method(ActionAgent::MCPToolDispatcher, :tool_definitions, counted) do
      with_method(ActionAgent::ScenarioEvaluationRunner, :discovery_warning, warned) do
        run_fanned_out(build_suite, models: [ "mock/alpha", "mock/beta" ])
      end
    end

    assert_equal "complete", run.status
    assert_equal 1, discoveries
    assert_equal "discovery warning 1", run.error_message, "the run's warning is the one found before the replays, whichever job completed it"
    assert_equal 1, warnings.size
  end

  test "a rule reads the agent's whole answer, not the 20,000 bytes the result keeps" do
    evaluation = build_suite
    # The mock provider answers in pig latin, so the digits come back followed by "ay".
    marker = "9999977777"
    evaluation.scenarios.create!(key: "long_1", prompt: "#{"#{'a' * 99} " * 220}#{marker}", expectations: { "contains" => [ marker ] })

    run = run_fanned_out(evaluation, keys: [ "long_1" ])

    row = run.scenario_results.sole
    assert_equal "complete", run.status
    assert_equal "passed", row.status
    assert_operator row.output.bytesize, :<=, 20_000
    assert_operator row.agent_run.output.bytesize, :>, 20_000
    assert_not_includes row.output, marker
  end

  test "a fanned-out run refuses a model listed twice under two labels" do
    run = build_suite.run_later!(keys: [ "tickets_1" ], models: [ "mock/alpha", "alpha" ])

    assert_raises(ArgumentError) { perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob) }

    assert_equal "failed", run.reload.status
    assert_match(/listed more than once \(mock\/alpha as mock\/alpha and alpha\)/, run.error_message)
    assert_empty enqueued_jobs.select { |job| job["job_class"] == "ActionAgent::EvaluationReplayJob" }
  end

  test "a result not yet scored reads as pending, not as a failure" do
    run = build_suite.run_later!(keys: [ "tickets_1" ])
    drain(only: [ ActionAgent::EvaluationRunJob, ActionAgent::EvaluationReplayJob ])
    pending = run.scenario_results.sole

    assert_equal "pending", ActionAgent::EvaluationFixComparison.change(nil, pending)
    assert_equal "pending", ActionAgent::EvaluationFixComparison.change(pending, pending)
    assert_empty run.to_report.results, "the report grades scored results only"
  end

  test "a pinned GPT judge uses OpenAI when both native providers are credentialed" do
    ActionAgent::ProviderKey.delete_all
    ActionAgent::ProviderKey.create!(provider: "anthropic", credential: "synthetic-anthropic-key")
    ActionAgent::ProviderKey.create!(provider: "openai", credential: "synthetic-openai-key")
    evaluation = build_suite
    evaluation.update!(judge_kind: "llm", judge_model: "gpt-4o-mini",
      criteria: [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is the answer useful?" } } ])
    ActionAgent.scenario_evaluation_fan_out = false
    requests = []
    VCR.turned_off do
      stub_request(:post, "https://api.anthropic.com/v1/messages").with { |request|
        requests << { provider: "anthropic", model: JSON.parse(request.body)["model"] }
        true
      }.to_return(status: 200, headers: { "content-type" => "application/json" }, body: {
        id: "msg_audit", type: "message", role: "assistant", model: "gpt-4o-mini",
        content: [ { type: "text", text: '{"score": 0.9}' } ], stop_reason: "end_turn", stop_sequence: nil,
        usage: { input_tokens: 10, output_tokens: 5 }
      }.to_json)
      stub_request(:post, "https://api.openai.com/v1/chat/completions").with { |request|
        requests << { provider: "openai", model: JSON.parse(request.body)["model"] }
        true
      }.to_return(status: 200, headers: { "content-type" => "application/json" }, body: {
        id: "chatcmpl_audit", object: "chat.completion", created: 1, model: "gpt-4o-mini",
        choices: [ { index: 0, message: { role: "assistant", content: '{"score": 0.9}' }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
      }.to_json)
      stub_request(:post, "https://api.openai.com/v1/responses").with { |request|
        requests << { provider: "openai", model: JSON.parse(request.body)["model"] }
        true
      }.to_return(status: 200, headers: { "content-type" => "application/json" }, body: {
        id: "resp_audit", object: "response", status: "completed", model: "gpt-4o-mini",
        output: [ { type: "message", id: "msg_audit", status: "completed", role: "assistant",
                    content: [ { type: "output_text", text: '{"score": 0.9}', annotations: [] } ] } ],
        usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
      }.to_json)
      ActiveAgent.stub(:configuration, {}) { evaluation.run!(keys: [ "tickets_1" ]) }
    end
    assert_equal [ { provider: "openai", model: "gpt-4o-mini" } ], requests.uniq
  ensure
    ActionAgent::ProviderKey.delete_all
  end
end
