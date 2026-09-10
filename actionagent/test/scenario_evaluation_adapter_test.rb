# frozen_string_literal: true

require "test_helper"

class ActionAgentScenarioEvaluationAdapterTest < ActiveSupport::TestCase
  def setup
    @previous_resolver = ActionAgent.scenario_evaluation_adapter_resolver
    @agent = ActionAgent::Agent.create!(name: "Support adapter", provider: "mock", model: "default", instructions: "Use order data.")
    @evaluation = @agent.evaluations.create!(name: "Order catalog", judge_kind: "llm", judge_model: "host-judge",
      criteria: [ { "key" => "response_present", "type" => "response_present" } ])
    @evaluation.scenarios.create!(key: "order_1", group: "orders", prompt: "Where is order ABC-123?", expectations: { "tools" => [ "lookup_order" ] })
    @evaluation.scenarios.create!(key: "help_1", group: "help", prompt: "How do returns work?")
    @owner = Object.new
    owner = @owner
    @agent.define_singleton_method(:owner) { owner }
    @agent.define_singleton_method(:test_execute) { |*, **| raise "default replay must not run" }
  end

  def teardown
    ActionAgent.scenario_evaluation_adapter_resolver = @previous_resolver
  end

  def host_report(scenarios:, models:, on_result:)
    judge = ActiveAgent::Evals::Judge.new(label: "host-judge") { |**| '{"score": 0.9}' }
    ActiveAgent::Evals::Runner.new(
      scenarios: scenarios, models: models, judge: judge, on_result: on_result,
      available_tools: [ "lookup_order" ],
      metadata: { "run_id" => "host-run-1", "scope" => "test-workspace", "judge_trace_ids" => [ "verdict-trace" ] },
      replay: ->(scenario, model) {
        ActiveAgent::Evals::Replay.new(answer: "Order ABC-123 shipped.", tool_calls: [ { name: "lookup_order" } ],
          metadata: { "result_id" => "#{scenario.key}-#{model.model}", "trace_id" => "trace-#{model.model}",
                      "judge_trace_ids" => [ "judge-#{model.model}" ], "role" => "support" })
      }
    ).call
  end

  test "a host adapter receives the selected scenarios models owner and judge configuration and persists its report" do
    ActionAgent.scenario_evaluation_adapter_resolver = lambda do |evaluation|
      assert_equal @evaluation, evaluation
      lambda do |evaluation:, owner:, scenarios:, models:, on_result:|
        assert_same @owner, owner
        assert_equal "llm", evaluation.judge_kind
        assert_equal "host-judge", evaluation.judge_model
        assert_equal [ "order_1" ], scenarios.map(&:key)
        assert_equal [ "lookup_order" ], scenarios.first.expected_tools
        assert_equal %w[mock/alpha mock/beta], models.map(&:label)
        host_report(scenarios: scenarios, models: models, on_result: on_result)
      end
    end

    run = nil
    assert_no_difference "ActionAgent::AgentRun.count" do
      run = @evaluation.run!(keys: [ "order_1" ], models: %w[mock/alpha mock/beta])
    end

    assert_equal "complete", run.status
    assert_equal 2, run.samples_evaluated
    assert_equal 2, run.samples_passed
    assert_equal 2, run.scenario_results.count
    assert_equal "host-run-1", run.reload.report_metadata["run_id"]
    assert_equal [ "verdict-trace" ], run.report_metadata["judge_trace_ids"]
    assert_equal "host-judge", run.judge_label
    result = run.scenario_results.find_by!(model: "alpha")
    assert_nil result.agent_run
    assert_equal "trace-alpha", result.as_json_summary[:metadata]["trace_id"]
    assert_equal [ "judge-alpha" ], result.as_json_summary[:metadata]["judge_trace_ids"]
    assert_empty result.as_json_summary[:diagnosis]

    report = run.to_report
    assert_equal run.report_metadata, report.metadata.slice(*run.report_metadata.keys)
    assert_equal %w[mock/alpha mock/beta], report.models.map(&:label)
    assert_equal "trace-alpha", report.results.find { |entry| entry.model == "alpha" }.replay.metadata["trace_id"]
    serialized = JSON.parse(report.to_json)
    assert_equal "host-run-1", serialized["metadata"]["run_id"]
    assert_equal "order_1-alpha", serialized["results"].find { |entry| entry["model"] == "alpha" }["metadata"]["result_id"]
    assert_includes report.to_html, "Order ABC-123 shipped."
  end

  test "an adapter failure preserves completed results and records the failed run" do
    ActionAgent.scenario_evaluation_adapter_resolver = ->(*) {
      lambda do |scenarios:, models:, on_result:, **|
        host_report(scenarios: scenarios.first(1), models: models.first(1), on_result: on_result)
        raise "host replay unavailable"
      end
    }

    error = assert_raises(RuntimeError) { @evaluation.run!(keys: [ "order_1" ], models: %w[mock/alpha mock/beta]) }

    assert_equal "host replay unavailable", error.message
    run = @evaluation.evaluation_runs.recent.first
    assert_equal "failed", run.status
    assert_equal "host replay unavailable", run.error_message
    assert run.completed_at
    assert_equal 1, run.scenario_results.count
    assert_equal "trace-alpha", run.scenario_results.first.replay_metadata["trace_id"]
  end

  test "refreshing a catalog and judge preserves earlier report questions expectations and ordering" do
    ActionAgent.scenario_evaluation_adapter_resolver = ->(*) {
      ->(scenarios:, models:, on_result:, **) { host_report(scenarios: scenarios, models: models, on_result: on_result) }
    }
    order = @evaluation.scenarios.find_by!(key: "order_1")
    order.update!(notes: "Use the original order lookup", position: 0)
    @evaluation.scenarios.find_by!(key: "help_1").update!(position: 1)
    run = @evaluation.run!(models: [ "mock/alpha" ])

    order.update!(prompt: "Cancel order DEF-456", group: "cancellations", notes: "Use the new cancellation tool",
      expectations: { "tools" => [ "cancel_order" ], "contains" => [ "cancelled" ] }, position: 9)
    @evaluation.update!(judge_model: "replacement-judge")

    historical = run.reload.to_report
    assert_equal %w[order_1 help_1], historical.results.map { |result| result.scenario.key }
    scenario = historical.results.first.scenario
    assert_equal "Where is order ABC-123?", scenario.prompt
    assert_equal "orders", scenario.group
    assert_equal "Use the original order lookup", scenario.notes
    assert_equal [ "lookup_order" ], scenario.expected_tools
    assert_empty scenario.expected_patterns
    assert_equal "host-judge", historical.judge_label
    assert_includes historical.to_html, "Where is order ABC-123?"
    refute_includes historical.to_html, "Cancel order DEF-456"
    summary = run.scenario_results.find_by!(evaluation_scenario_id: order.id).as_json_summary
    assert_equal "Where is order ABC-123?", summary[:prompt]
    assert_equal "orders", summary[:group]
    assert_equal [ "lookup_order" ], summary[:scenario]["expectations"]["tools"]
    assert_empty summary[:diagnosis]

    current = @evaluation.run!(keys: [ "order_1" ], models: [ "mock/alpha" ]).to_report.results.first.scenario
    assert_equal "Cancel order DEF-456", current.prompt
    assert_equal [ "cancel_order" ], current.expected_tools
  end

  test "legacy results without a scenario snapshot remain readable" do
    run = @evaluation.evaluation_runs.create!(status: :complete)
    scenario = @evaluation.scenarios.find_by!(key: "order_1")
    row = run.scenario_results.create!(scenario: scenario, provider: "mock", model: "alpha", status: :passed,
      score: 1, scores: {}, diagnosis: {}, output: "An earlier answer")

    assert_equal scenario.prompt, row.as_json_summary[:prompt]
    assert_equal scenario.expected_tools, run.to_report.results.first.scenario.expected_tools
  end

  test "an adapter that returns an incomplete or unpersisted report fails instead of showing a completed empty dashboard" do
    ActionAgent.scenario_evaluation_adapter_resolver = ->(*) {
      ->(scenarios:, models:, **options) { host_report(scenarios: scenarios, models: models, on_result: nil) }
    }

    assert_raises(ArgumentError) { @evaluation.run!(keys: [ "order_1" ]) }
    assert_equal "failed", @evaluation.evaluation_runs.recent.first.status
    assert_match(/persist every selected/, @evaluation.evaluation_runs.recent.first.error_message)
  end

  test "nil from the resolver retains the default execution path" do
    ActionAgent.scenario_evaluation_adapter_resolver = ->(*) { nil }
    @agent.singleton_class.remove_method(:test_execute)

    run = @evaluation.run!(keys: [ "help_1" ])

    assert_equal "complete", run.status
    assert run.scenario_results.first.agent_run
  end
end
