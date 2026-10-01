# frozen_string_literal: true

require "test_helper"
require_relative "support/ruby_llm_constant"

# A tenant and a trace table with a tenant column, for the multi-tenant
# cases: the dummy app configures neither.
class CostTestAccount < ActiveRecord::Base
  def self.ensure_table!
    return if connection.table_exists?(:cost_test_accounts)

    connection.create_table(:cost_test_accounts) { |t| t.string :name }
  end
end
CostTestAccount.ensure_table!

class CostTenantTrace < ActionAgent::TelemetryTrace
  self.table_name = "cost_tenant_traces"

  def self.ensure_table!
    return if connection.table_exists?(:cost_tenant_traces)

    connection.create_table :cost_tenant_traces do |t|
      t.string :trace_id, null: false
      t.bigint :account_id
      t.bigint :agent_id
      t.bigint :agent_version_id
      t.string :agent_class
      t.string :agent_action
      t.string :service_name
      t.string :environment
      t.string :status
      t.text :error_message
      t.datetime :timestamp
      t.decimal :total_duration_ms, precision: 12, scale: 3
      t.integer :total_input_tokens, default: 0
      t.integer :total_output_tokens, default: 0
      t.integer :total_thinking_tokens, default: 0
      t.json :spans, default: []
      t.json :resource_attributes, default: {}
      t.json :sdk_info, default: {}
      t.timestamps
    end
  end
end
CostTenantTrace.ensure_table!

# Every result priced, down the chain EvaluationRunCost describes, and the
# judge's spend found from the meter, the application or the traces.
class ActionAgentEvaluationRunCostTest < ActiveSupport::TestCase
  include RubyLLMConstant

  Pricing = ActionAgent::ModelPricing

  # Agent.delete_all skips callbacks, so the runs are removed first: a run
  # left behind would count against another file's "stores nothing".
  setup do
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
    CostTenantTrace.delete_all
    Pricing.reset!
  end

  teardown do
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
    ActionAgent.trace_model_class = nil
    Pricing.reset!
  end

  def suite(agent_attributes: {})
    agent = ActionAgent::Agent.create!({ name: "Support", provider: "openai", model: "gpt-4o-mini" }.merge(agent_attributes))
    evaluation = agent.evaluations.create!(
      name: "Orders", judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    evaluation.scenarios.create!(key: "s1", prompt: "Where is order 1234?", position: 0)
    evaluation.scenarios.create!(key: "s2", prompt: "Can I get a refund?", position: 1)
    evaluation
  end

  # An imported run (published by an application), as EvaluationReportImport stores one.
  def imported_run(evaluation, scores: {}, tenant: "")
    evaluation.evaluation_runs.create!(
      status: :complete, external_tenant: tenant, external_run_id: "run-#{SecureRandom.hex(4)}",
      external_report_digest: "d", completed_at: Time.current, scores: scores,
      selection: { "models" => [ { "label" => "gpt-4o-mini", "provider" => "openai", "model" => "gpt-4o-mini" } ] }
    )
  end

  def result(run, key, **attributes)
    scenario = run.evaluation.scenarios.find_by!(key: key)
    defaults = { scenario: scenario, model: "gpt-4o-mini", provider: "openai", status: :passed, score: 1.0, output: "Order 1234 shipped." }
    run.scenario_results.create!(defaults.merge(attributes))
  end

  def llm_span(model, provider: "openai")
    { "span_id" => "l1", "parent_span_id" => "r1", "type" => "llm", "attributes" => { "llm.model" => model, "llm.provider" => provider } }
  end

  def trace(trace_id, input:, output:, thinking: 0, model: "gpt-4o-mini", action: nil, model_class: ActionAgent::TelemetryTrace, account_id: nil)
    attributes = { trace_id: trace_id, total_input_tokens: input, total_output_tokens: output, total_thinking_tokens: thinking,
                   agent_action: action, spans: [ llm_span(model) ], timestamp: Time.current, status: "OK" }
    attributes[:account_id] = account_id if account_id
    model_class.create!(attributes)
  end

  test "an imported result's cost is reported, and one without a cost is estimated from its tokens at the model's rate" do
    without_ruby_llm do
      run = imported_run(suite)
      reported = result(run, "s1", cost: 0.0004, input_tokens: 100, output_tokens: 20)
      tokens = result(run, "s2", cost: nil, input_tokens: 2_000, output_tokens: 100)

      breakdown = run.cost_breakdown
      assert_equal({ "cost" => 0.0004, "reported_cost" => 0.0004, "cost_source" => "reported", "cost_rate" => nil, "judge_usage" => nil },
                   breakdown.result(reported))
      entry = breakdown.result(tokens)
      assert_in_delta 0.00036, entry["cost"], 1e-9
      assert_nil entry["reported_cost"]
      assert_equal "estimated", entry["cost_source"]
      assert_equal({ "input" => 0.15, "output" => 0.6, "source" => "pattern", "basis" => "tokens", "input_tokens" => 2_000, "output_tokens" => 100 },
                   entry["cost_rate"])

      usage = run.usage
      assert_equal [ 2, 2, 0, 1, 1, "mixed" ], usage.values_at(:replays, :priced, :unpriced, :reported, :estimated, :cost_basis)
      assert_in_delta 0.00076, usage[:cost], 1e-9
      assert_in_delta 0.00038, usage[:per_interaction], 1e-9
      assert_in_delta 0.00076, usage[:total], 1e-9
      assert_nil usage[:judge]
    end
  end

  test "a result that recorded no usage costs nothing, and says so rather than going unpriced" do
    run = imported_run(suite)
    errored = result(run, "s1", status: :errored, score: nil, output: nil, error_message: "boom", cost: nil, input_tokens: 0, output_tokens: 0)

    entry = run.cost_breakdown.result(errored)
    assert_equal [ 0.0, nil, "no_usage", nil ], entry.values_at("cost", "reported_cost", "cost_source", "cost_rate")
    assert_equal 1, run.usage[:priced]
    assert_equal 0.0, run.usage[:cost]
  end

  test "a result with no tokens is priced from the trace it links to, whose thinking tokens are already in its output" do
    without_ruby_llm do
      run = imported_run(suite)
      trace("t-answer", input: 1_000, output: 200, thinking: 50, model: "gpt-4o")
      traced = result(run, "s1", cost: nil, input_tokens: nil, output_tokens: nil,
                      diagnosis: { "_replay_metadata" => { "trace_id" => "t-answer" } })

      entry = run.cost_breakdown.result(traced)
      assert_equal "estimated", entry["cost_source"]
      assert_in_delta Pricing.estimate(model: "gpt-4o", input_tokens: 1_000, output_tokens: 200), entry["cost"], 1e-9
      assert_equal [ "trace", 1_000, 200 ], entry["cost_rate"].values_at("basis", "input_tokens", "output_tokens")
      assert_equal 2.5, entry["cost_rate"]["input"], "the trace's own model sets the rate"
    end
  end

  test "a result with no tokens and no trace is priced from its text as a lower bound, and one with nothing at all stays unpriced" do
    without_ruby_llm do
      run = imported_run(suite)
      text = result(run, "s1", cost: nil, input_tokens: nil, output_tokens: nil, output: "x" * 400)
      nothing = result(run, "s2", cost: nil, input_tokens: nil, output_tokens: nil, output: nil,
                       diagnosis: { "_scenario_snapshot" => { "key" => "s2", "prompt" => "", "position" => 1 } })

      entry = run.cost_breakdown.result(text)
      assert_equal "estimated", entry["cost_source"]
      assert_equal [ "chars", "Where is order 1234?".length / 4, 100 ], entry["cost_rate"].values_at("basis", "input_tokens", "output_tokens")
      assert_equal "unpriced", run.cost_breakdown.result(nothing)["cost_source"]
      assert_equal [ 2, 1, 1 ], run.usage.values_at(:replays, :priced, :unpriced)
    end
  end

  test "a run the engine executed keeps its stored estimate, marked as one, with the model's rate" do
    without_ruby_llm do
      evaluation = suite
      run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
      stored = result(run, "s1", cost: 0.000123, input_tokens: 100, output_tokens: 20)

      entry = run.cost_breakdown.result(stored)
      assert_equal [ 0.000123, nil, "estimated" ], entry.values_at("cost", "reported_cost", "cost_source")
      assert_equal "pattern", entry.dig("cost_rate", "source")
      assert_equal "estimated", run.usage[:cost_basis]
    end
  end

  test "the judge's spend comes from the judge traces, input and output tokens only, run-level traces apart" do
    without_ruby_llm do
      run = imported_run(suite, scores: { "_metadata" => { "judge_trace_ids" => [ "j-verdict" ] } })
      trace("j-score", input: 400, output: 20, thinking: 10, model: "claude-opus-5", action: "score")
      trace("j-verdict", input: 900, output: 60, model: "claude-opus-5", action: "verdict")
      scored = result(run, "s1", cost: 0.0004, input_tokens: 100, output_tokens: 20,
                      diagnosis: { "_replay_metadata" => { "judge_trace_ids" => [ "j-score" ] } })
      result(run, "s2", cost: 0.0004, input_tokens: 100, output_tokens: 20)

      judge = run.judge_usage
      score_cost = Pricing.estimate(model: "claude-opus-5", input_tokens: 400, output_tokens: 20)
      verdict_cost = Pricing.estimate(model: "claude-opus-5", input_tokens: 900, output_tokens: 60)
      assert_equal [ 2, 1_300, 80, "claude-opus-5", "traces", true ], judge.values_at("calls", "input_tokens", "output_tokens", "model", "source", "estimated")
      assert_in_delta score_cost + verdict_cost, judge["cost"], 1e-9, "the 10 thinking tokens are never priced again"
      assert_equal({ "score" => 1, "verdict" => 1 }, judge["by_kind"])
      assert_equal 1, judge.dig("run", "calls")
      assert_in_delta verdict_cost, judge.dig("run", "cost"), 1e-9

      per_result = run.cost_breakdown.result(scored)["judge_usage"]
      assert_equal [ 1, 400, 20, "traces" ], per_result.values_at("calls", "input_tokens", "output_tokens", "source")
      assert_in_delta score_cost, per_result["cost"], 1e-9

      usage = run.usage
      assert_in_delta 0.0008 + score_cost + verdict_cost, usage[:total], 1e-9
      costs = run.cost_breakdown.costs
      assert_in_delta score_cost, costs.dig("scenarios", "s1", "judge_cost"), 1e-9
      assert_nil costs.dig("scenarios", "s2", "judge_cost")
      assert_equal "reported", costs.dig("run", "cost_basis")
      assert_in_delta verdict_cost + score_cost, costs.dig("run", "judge_cost"), 1e-9
    end
  end

  test "the engine's own meter outranks everything else, and a result then carries no judge usage of its own" do
    meter = { "calls" => 3, "input_tokens" => 900, "output_tokens" => 36, "cost" => 0.0054, "model" => "claude-opus-5",
              "by_kind" => { "score" => 2, "verdict" => 1 } }
    run = suite.evaluation_runs.create!(status: :complete, completed_at: Time.current, scores: { "_judge_usage" => meter })
    trace("j-ignored", input: 9_000, output: 900, model: "claude-opus-5")
    scored = result(run, "s1", cost: 0.001, diagnosis: { "_replay_metadata" => { "judge_trace_ids" => [ "j-ignored" ] } })

    judge = run.judge_usage
    assert_equal meter.merge("source" => "meter", "estimated" => true, "run" => { "calls" => 1, "cost" => nil, "by_kind" => { "verdict" => 1 } }), judge
    assert_nil run.cost_breakdown.result(scored)["judge_usage"]
    assert_equal judge, run.usage[:judge]
  end

  test "what the application reported for the judge is used as reported, and a part sent without a cost is priced" do
    without_ruby_llm do
      run = imported_run(suite, scores: { "_judge_usage_run" => { "calls" => 1, "input_tokens" => 500, "output_tokens" => 40, "cost" => 0.004,
                                                                   "model" => "judge-1", "by_kind" => { "verdict" => 1 }, "source" => "reported" } })
      scored = result(run, "s1", cost: 0.0004, diagnosis: {
        "_judge_usage" => { "calls" => 2, "input_tokens" => 800, "output_tokens" => 40, "model" => "claude-opus-5", "by_kind" => { "score" => 2 } }
      })

      judge = run.judge_usage
      priced = Pricing.estimate(model: "claude-opus-5", input_tokens: 800, output_tokens: 40)
      assert_equal [ 3, 1_300, 80, "reported", true ], judge.values_at("calls", "input_tokens", "output_tokens", "source", "estimated")
      assert_in_delta 0.004 + priced, judge["cost"], 1e-9
      assert_equal({ "score" => 2, "verdict" => 1 }, judge["by_kind"])
      assert_equal({ "calls" => 1, "cost" => 0.004, "by_kind" => { "verdict" => 1 } }, judge["run"])
      assert_in_delta priced, run.cost_breakdown.result(scored).dig("judge_usage", "cost"), 1e-9
      assert_not run.scenario_results.first.as_json_summary[:diagnosis].key?("_judge_usage"), "the stored usage stays out of the visible diagnosis"
    end
  end

  test "traces are read within the run's tenant and never another tenant's" do
    without_ruby_llm do
      ActionAgent.multi_tenant = true
      ActionAgent.account_class = "CostTestAccount"
      ActionAgent.trace_model_class = "CostTenantTrace"
      mine = CostTestAccount.create!(name: "mine")
      other = CostTestAccount.create!(name: "other")
      trace("j-mine", input: 400, output: 20, model: "claude-opus-5", action: "score", model_class: CostTenantTrace, account_id: mine.id)
      trace("j-other", input: 4_000, output: 200, model: "claude-opus-5", action: "score", model_class: CostTenantTrace, account_id: other.id)
      trace("t-other", input: 4_000, output: 200, model: "gpt-4o", model_class: CostTenantTrace, account_id: other.id)
      run = imported_run(suite, tenant: mine.id.to_s)
      result(run, "s1", cost: 0.0004, diagnosis: { "_replay_metadata" => { "judge_trace_ids" => [ "j-mine", "j-other" ] } })
      foreign = result(run, "s2", cost: nil, input_tokens: nil, output_tokens: nil, output: nil,
                       diagnosis: { "_replay_metadata" => { "trace_id" => "t-other" }, "_scenario_snapshot" => { "key" => "s2", "prompt" => "", "position" => 1 } })

      judge = run.judge_usage
      assert_equal [ 1, 400 ], judge.values_at("calls", "input_tokens"), "the other tenant's judge trace is invisible"
      assert_equal "unpriced", run.cost_breakdown.result(foreign)["cost_source"], "the other tenant's replay trace is invisible"

      homeless = imported_run(suite, tenant: "")
      result(homeless, "s1", cost: 0.0004, diagnosis: { "_replay_metadata" => { "judge_trace_ids" => [ "j-mine" ] } })
      assert_nil homeless.judge_usage, "a run with no tenant reads no traces on a multi-tenant install"
    end
  end

  test "the rebuilt report prices every replay and names the judge, and an older framework's Report is not handed what it cannot take" do
    without_ruby_llm do
      run = imported_run(suite, scores: { "_metadata" => { "judge_trace_ids" => [ "j-verdict" ] } })
      trace("j-verdict", input: 900, output: 60, model: "claude-opus-5", action: "verdict")
      result(run, "s1", cost: 0.0004, input_tokens: 100, output_tokens: 20)
      result(run, "s2", cost: nil, input_tokens: 2_000, output_tokens: 100)
      version = run.evaluation.agent.find_or_record_release!(digest: "abc123def456", revision: "deploy-1")
      run.update!(agent_version: version)

      report = run.to_report
      costs = report.summary_by_model["gpt-4o-mini"]
      assert_equal [ 2, 1, 1 ], costs.values_at("priced", "reported", "estimated")
      assert_in_delta 0.00076, costs["cost"], 1e-9
      assert_equal 1, report.judge_usage["calls"]
      assert_equal 1, report.judge_usage.dig("run", "calls")
      assert_equal({ "digest" => "abc123def456", "revision" => "deploy-1", "label" => "v#{version.version_number}" }, report.release)
      assert_includes report.to_html, "~$"

      recorded = run.to_report(estimate: false).summary_by_model["gpt-4o-mini"]
      assert_equal [ 1, 1, 0, 0.0004 ], recorded.values_at("priced", "reported", "estimated", "cost"), "what the application reported, nothing estimated"

      older = Class.new(ActiveAgent::Evals::Report) do
        def initialize(results:, models:, judge: nil, instructions: nil, threshold: 0.7, metadata: {}, tool_resolver: nil,
                       agent_name: nil, links: {}, verdict: nil, judge_label: nil)
          super
        end
      end
      ActionAgent::EvaluationRun.stub(:report_class, older) do
        rebuilt = run.to_report
        assert_kind_of older, rebuilt
        assert_nil rebuilt.release
      end
    end
  end

  test "preload prices a page of runs with one query for their results and one for their traces" do
    without_ruby_llm do
      evaluation = suite
      runs = 2.times.map do |index|
        run = imported_run(evaluation)
        trace("t-#{index}", input: 500, output: 50)
        result(run, "s1", cost: nil, input_tokens: nil, output_tokens: nil, diagnosis: { "_replay_metadata" => { "trace_id" => "t-#{index}" } })
        run
      end
      fresh = ActionAgent::EvaluationRun.where(id: runs.map(&:id)).to_a

      queries = []
      counter = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:sql] =~ /SCHEMA|TRANSACTION/i }
      breakdowns = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ActionAgent::EvaluationRunCost.preload(fresh) }

      assert_equal fresh.map(&:id).sort, breakdowns.keys.sort
      assert_equal 1, queries.count { |sql| sql.include?("evaluation_scenario_results") }
      assert_equal 1, queries.count { |sql| sql.include?("telemetry_traces") }
      assert breakdowns.values.all? { |breakdown| breakdown.usage[:cost].to_f.positive? }
    end
  end

  test "a finished run's figures are cached under the run, its update time and the pricing tables" do
    without_ruby_llm do
      run = imported_run(suite)
      result(run, "s1", cost: nil, input_tokens: 1_000, output_tokens: 100)
      store = ActiveSupport::Cache::MemoryStore.new

      Rails.stub(:cache, store) do
        first = ActionAgent::EvaluationRunCost.for(run).usage[:cost]
        assert_equal 1, store.instance_variable_get(:@data).size
        run.scenario_results.first.update_columns(input_tokens: 5_000)
        assert_equal first, ActionAgent::EvaluationRunCost.for(run).usage[:cost], "the cached figure stands until the run changes"
        run.touch
        assert_operator ActionAgent::EvaluationRunCost.for(run.reload).usage[:cost], :>, first
      end

      pending = run.evaluation.evaluation_runs.create!(status: :running)
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
        assert_nil ActionAgent::EvaluationRunCost.for(pending).usage
        assert_empty Rails.cache.instance_variable_get(:@data), "a run still landing results is not cached"
      end
    end
  end
end
