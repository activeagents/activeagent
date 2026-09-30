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

  # Captures the actor each replay hands Agent#test_execute.
  def capture_replay_actors(evaluation)
    seen = []
    agent = evaluation.agent
    fake_run = agent.agent_runs.create!(status: :complete, trace_id: SecureRandom.uuid, input_prompt: "x", output: "done")
    agent.define_singleton_method(:test_execute) { |*, **options| seen << options[:actor]; fake_run }
    yield
    seen
  end

  test "a replay runs as the evaluation's owner when agents are owned per user" do
    previous = ActionAgent.user_class
    ActionAgent.user_class = "User"
    user = User.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com", age: 30)
    evaluation = build_suite(user_id: user.id)

    actors = capture_replay_actors(evaluation) { evaluation.run!(keys: [ "tickets_1" ]) }

    assert_equal [ user ], actors, "every tool the replay calls should be scoped to the owner"
  ensure
    ActionAgent.user_class = previous
    user&.destroy
  end

  test "a replay is unattributed when the install has no owner model" do
    previous = ActionAgent.user_class
    ActionAgent.user_class = nil
    evaluation = build_suite

    actors = capture_replay_actors(evaluation) { evaluation.run!(keys: [ "tickets_1" ]) }

    assert_equal [ nil ], actors
  ensure
    ActionAgent.user_class = previous
  end

  # Runs the block with the host's credentials for +provider+ blanked, so a
  # replay through it fails at the execution service's credential gate rather
  # than at the network. CI decrypts the reference host's credentials, so
  # without this the outcome depends on which keys the environment holds.
  def without_provider_credentials(provider)
    config = ActiveAgent.configuration
    original = config[provider]
    config[provider] = (original || {}).to_h.except("access_token", "api_key")
    yield
  ensure
    config[provider] = original
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

    run = evaluation.run!(group: "History")

    assert_equal [ "history_1" ], run.scenario_results.map { |result| result.scenario.key }
    assert_equal [ "history_1" ], run.selection["scenario_keys"]
    assert_equal "History", run.selection["group"]
    assert_equal [ "mock-model" ], run.models
  end

  test "keys and scenario_ids select individual scenarios" do
    evaluation = build_suite
    tickets_two = evaluation.scenarios.find_by!(key: "tickets_2")

    by_key = evaluation.run!(keys: [ "tickets_1" ])
    by_id = evaluation.run!(scenario_ids: [ tickets_two.id ])

    assert_equal [ "tickets_1" ], by_key.scenario_results.map { |result| result.scenario.key }
    assert_equal [ "tickets_2" ], by_id.scenario_results.map { |result| result.scenario.key }
  end

  test "an empty selection fails the run rather than silently running nothing" do
    evaluation = build_suite

    run = evaluation.run!(group: "Nope")

    assert_equal "failed", run.status
    assert_match(/No scenarios selected/, run.error_message)
  end

  test "a disabled scenario is skipped" do
    evaluation = build_suite
    evaluation.scenarios.find_by!(key: "tickets_1").update!(enabled: false)

    run = evaluation.run!

    assert_equal %w[history_1 tickets_2], run.scenario_results.map { |result| result.scenario.key }.sort
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

    run = evaluation.run!(keys: [ "tickets_2" ])
    result = run.scenario_results.first

    assert_equal "failed", result.status
    assert_equal "expected_tool_not_called", result.fault
    assert_equal 0.0, result.scores["expected_tools"]
    assert_match(/find_tickets/, result.recommendation)

    recommendation = run.scores["_recommendations"].first
    assert_equal "expected_tool_not_called", recommendation["fault"]
    assert_equal [ "tickets_2" ], recommendation["scenario_keys"]
    assert_equal 1, recommendation["count"]
    assert_equal({ "expected_tool_not_called" => 1 }, run.scores["_models"]["mock-model"]["faults"])
  end

  test "a scenario the mock provider answers passes when nothing is expected of the answer" do
    evaluation = build_suite

    run = evaluation.run!(keys: [ "tickets_1" ])
    result = run.scenario_results.first

    assert_equal "passed", result.status
    assert_nil result.fault
    assert_equal 1.0, result.score
    assert_equal 1, run.samples_passed
  end

  test "a failed replay is an errored result with a run_error fault, and the run still completes" do
    evaluation = build_suite(provider: "anthropic", model: "claude-sonnet-5")

    run = without_provider_credentials("anthropic") { evaluation.run!(keys: [ "tickets_1" ]) }
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
      status: :complete, trace_id: SecureRandom.uuid, input_prompt: "x", output: "Found 3 tickets.",
      duration_ms: 120, input_tokens: 10, output_tokens: 5,
      logs: [
        { "eid" => "1-1", "kind" => "tool", "label" => "find_tickets", "status" => "started", "detail" => { "status" => "open" }.to_json },
        { "eid" => "1-1", "kind" => "tool", "label" => "find_tickets", "status" => "done", "duration_ms" => 40, "detail" => "3 rows" }
      ]
    )
    agent.define_singleton_method(:test_execute) { |*, **| fake_run }

    run = evaluation.run!(keys: [ "tickets_2" ])
    result = run.scenario_results.first

    assert_equal "passed", result.status
    assert_equal [ { "name" => "find_tickets", "arguments" => { "status" => "open" }, "error" => false, "detail" => "3 rows", "duration_ms" => 40 } ],
      result.tool_calls
    assert_equal 1.0, result.scores["expected_tools"]
    assert_equal 1.0, result.scores["tools_succeeded"]
    assert_in_delta 0.000045, result.cost.to_f, 0.0001
  end

  # The judge's spend is the evaluation's own overhead, not the agent's; the
  # runner meters every judge call under what it was for so the dashboard
  # can show the replays' cost (operating the agent) apart from the judge's.
  test "a judged run records the judge's calls and cost apart from the replays'" do
    evaluation = build_suite
    evaluation.update!(judge_kind: "llm", judge_model: "claude-opus-5",
      criteria: [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is the answer useful?" } } ])
    reply = Struct.new(:content, :input_tokens, :output_tokens, :model) do
      def message = Struct.new(:content).new(content)
      def usage = Struct.new(:input_tokens, :output_tokens).new(input_tokens, output_tokens)
      def generate_now = self
    end
    judge = Class.new do
      define_singleton_method(:prompt) do |message:, instructions:|
        content = if instructions.include?("comparing model cohorts")
          { winner: "mock/alpha", rationale: "Marginally better." }.to_json
        elsif instructions.include?("recommend the fix")
          { recommendation: "Enable find_tickets.", suggested_tool: nil, instruction_change: nil }.to_json
        else
          { score: 0.9 }.to_json
        end
        reply.new(content, 200, 10, "claude-opus-5")
      end
    end

    runner = ActionAgent::ScenarioEvaluationRunner.new(evaluation, selection: { keys: %w[tickets_1 tickets_2], models: [ "mock/alpha", "mock/beta" ] })
    run = runner.stub(:judge_provider, :anthropic) do
      runner.stub(:judge_class, judge) { runner.call }
    end

    assert_equal "complete", run.status
    usage = run.scores["_judge_usage"]
    assert usage["calls"].positive?
    # Every replay's answer was scored, the two cohorts got a verdict, and the
    # missing expected tool asked for a recommendation.
    assert_equal 4, usage.dig("by_kind", "score")
    assert_equal 1, usage.dig("by_kind", "verdict")
    assert usage.dig("by_kind", "recommend").to_i >= 1
    assert_equal usage["by_kind"].values.sum, usage["calls"]
    assert_equal 200 * usage["calls"], usage["input_tokens"]
    assert_equal "claude-opus-5", usage["model"]
    assert_in_delta ActionAgent::ModelPricing.estimate(model: "claude-opus-5", input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"]),
                    usage["cost"], 1e-9
    assert_equal "claude-opus-5", run.scores["_judge_label"]
    assert_equal "mock/alpha", run.scores.dig("_verdict", "winner")

    # EvaluationRun#usage keeps the two sides apart.
    assert_equal 4, run.usage[:replays]
    assert_equal usage, run.usage[:judge]
  end

  test "a rules-only run records no judge spend" do
    run = build_suite.run!(keys: [ "tickets_1" ])

    assert_equal "complete", run.status
    assert_nil run.scores["_judge_usage"]
    assert_nil run.usage[:judge]
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

    run = evaluation.run_later!(group: "History")
    assert_equal "pending", run.status

    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)

    assert_equal "complete", run.reload.status
    assert_equal [ "history_1" ], run.scenario_results.map { |result| result.scenario.key }
  end

  test "replace_scenarios! keeps the records whose keys survive" do
    evaluation = build_suite
    original = evaluation.scenarios.find_by!(key: "tickets_1")

    evaluation.replace_scenarios!(ActiveAgent::Evals::ScenarioParser.parse("# Tickets\nA rewritten first question\n# Search\nWhy is this article not showing?"))

    assert_equal %w[tickets_1 search_1], evaluation.scenarios.ordered.map(&:key)
    assert_equal original.id, evaluation.scenarios.find_by!(key: "tickets_1").id
    assert_equal "A rewritten first question", original.reload.prompt
  end

  test "replace_scenarios! keeps a surviving scenario's enabled flag" do
    evaluation = build_suite
    evaluation.scenarios.find_by!(key: "tickets_1").update!(enabled: false)

    evaluation.replace_scenarios!(ActiveAgent::Evals::ScenarioParser.parse("# Tickets\nA rewritten first question | key: tickets_1\nA new one | key: tickets_9"))

    assert_not evaluation.scenarios.find_by!(key: "tickets_1").enabled
    assert evaluation.scenarios.find_by!(key: "tickets_9").enabled
  end

  test "replace_scenarios! with on_removed: :disable keeps a dropped scenario and its results readable" do
    evaluation = build_suite
    dropped = evaluation.scenarios.find_by!(key: "history_1")

    evaluation.replace_scenarios!([ { "key" => "tickets_1", "prompt" => "A rewritten first question", "group" => "Tickets" } ],
      on_removed: :disable)

    assert_equal dropped.id, evaluation.scenarios.find_by!(key: "history_1").id
    assert_not dropped.reload.enabled, "a scenario the suite no longer names is disabled, not destroyed"
    assert_equal %w[tickets_1], evaluation.scenarios.enabled.ordered.map(&:key)
  end

  test "replace_scenarios! destroys a dropped scenario by default" do
    evaluation = build_suite

    evaluation.replace_scenarios!([ { "key" => "tickets_1", "prompt" => "A rewritten first question", "group" => "Tickets" } ])

    assert_nil evaluation.scenarios.find_by(key: "history_1")
  end

  test "replace_scenarios! rejects an unknown on_removed" do
    evaluation = build_suite

    assert_raises(ArgumentError) do
      evaluation.replace_scenarios!([ { "key" => "tickets_1", "prompt" => "Anything" } ], on_removed: :archive)
    end
  end

  test "each replay is reported to the host as one execution" do
    evaluation = build_suite
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind) { recorded << [ owner, kind ] }

    evaluation.run!(models: [ "mock/alpha", "mock/beta" ])

    assert_equal [ [ nil, :execution ] ] * 6, recorded
  ensure
    ActionAgent.usage_recorder = nil
  end

  test "a pending run whose suite lost its scenarios before the job ran is failed, not left pending" do
    evaluation = build_suite
    run = evaluation.run_later!
    evaluation.scenarios.destroy_all

    perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob)

    assert_equal "failed", run.reload.status
    assert_match(/No scenarios selected/, run.error_message)
    assert_equal [ run.id ], evaluation.evaluation_runs.ids
  end

  # #425: a run whose MCP servers all failed discovery scored an agent that had
  # no tools to call. Without this the only evidence was a logger.warn, and the
  # report recommended prompt changes for a transport failure.
  test "a run whose every MCP server failed discovery says so on the run" do
    evaluation = build_suite(mcp_servers: %w[tickets])

    with_unreachable_mcp_server do
      evaluation.run!(models: [ "mock/alpha" ])
    end

    run = evaluation.evaluation_runs.order(:created_at).last
    assert_equal "complete", run.status
    assert_match(/Every MCP server this agent declares failed tool discovery/, run.error_message)
    assert_match(/tickets/, run.error_message)
    assert_match(/401 Unauthorized/, run.error_message)
  end

  test "a run whose servers answer records no discovery warning" do
    evaluation = build_suite

    evaluation.run!(models: [ "mock/alpha" ])

    run = evaluation.evaluation_runs.order(:created_at).last
    assert_equal "complete", run.status
    assert_nil run.error_message
  end

  # Registers a catalog server the agent declares, whose tools/list refuses.
  def with_unreachable_mcp_server
    original = ActionAgent.mcp_catalog
    ActionAgent.mcp_catalog = [
      { key: "tickets", name: "Tickets", description: "Ticket lookups.",
        transport: "http", url: "https://host.example/mcp/tickets",
        tool_hints: %w[find_tickets] }
    ]

    refuser = Class.new do
      def list_tools = raise(ActionAgent::MCPClient::Error, "401 Unauthorized")
      def call_tool(_name, _arguments) = raise(ActionAgent::MCPClient::Error, "401 Unauthorized")
    end.new

    ActionAgent::MCPClient.stub(:new, refuser) { yield }
  ensure
    ActionAgent.mcp_catalog = original
  end
end
