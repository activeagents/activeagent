# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsCorrelationTest < ActiveSupport::TestCase
  include EvalsTestSupport

  # Stands in for a telemetry adapter, recording every trace it was asked to open.
  class RecordingTracer
    Trace = Struct.new(:trace_id)

    attr_reader :traces

    def initialize
      @traces = []
      @sequence = 0
    end

    def to_proc
      method(:call).to_proc
    end

    def call(name, action:, attributes:, on_trace:, &block)
      @sequence += 1
      trace_id = "trace-#{@sequence}"
      @traces << { name: name, action: action, attributes: attributes, trace_id: trace_id }
      on_trace&.call(Trace.new(trace_id))
      block.call
    end
  end

  def setup
    @tracer = RecordingTracer.new
    @correlation = ActiveAgent::Evals::Correlation.new(agent_name: "SupportAgent", judge_name: "SupportJudge",
                                                       tracer: @tracer.to_proc)
  end

  def test_a_run_mints_identities_that_reach_every_result_and_its_replay_trace
    report = run_evaluation(scenarios: [ scenario("lookup_1"), scenario("lookup_2") ])

    result_ids = report.results.map { |result| result.replay.metadata.fetch("result_id") }
    assert_equal 2, result_ids.uniq.size, "each evaluation should mint its own result identity"
    report.results.each do |result|
      metadata = result.replay.metadata
      assert_equal "run-1", metadata["run_id"], "the run identity should reach every result"
      assert_equal result.scenario.key, metadata["scenario_key"]
      assert_equal result.spec.label, metadata["model_label"]
      replay_trace = @tracer.traces.find { |trace| trace[:trace_id] == metadata.fetch("trace_id") }
      assert replay_trace, "the replay's trace id should land on the result's replay metadata"
      assert_equal "SupportAgent", replay_trace[:name]
    end
  end

  def test_correlation_rides_a_trace_as_eval_prefixed_attributes
    run_evaluation(scenarios: [ scenario("lookup_1") ])

    replay_trace = @tracer.traces.find { |trace| trace[:name] == "SupportAgent" }
    assert_equal({
      "eval.run_id" => "run-1",
      "eval.suite" => "support",
      "eval.result_id" => replay_trace[:attributes].fetch("eval.result_id"),
      "eval.scenario_key" => "lookup_1",
      "eval.model_label" => "test-model",
      "eval.model" => "test-model",
      "eval.provider" => "openai"
    }, replay_trace[:attributes])
  end

  def test_opaque_run_metadata_stays_off_the_traces
    @correlation.with_run("suite" => "support", "tenant" => "acme") do |metadata|
      @correlation.replay { nil }
      assert_equal "acme", metadata["tenant"], "the caller's own metadata should stay on the run"
    end

    refute_includes @tracer.traces.first[:attributes].keys, "eval.tenant"
  end

  def test_judge_traffic_routes_to_the_result_and_the_verdict_to_the_run
    metadata = nil
    report = run_evaluation(scenarios: [ scenario("lookup_1") ], judge: judge_calling("score")) { |run| metadata = run }
    @correlation.with_run(metadata) { @correlation.judge("verdict") { nil } }

    result_metadata = report.results.first.replay.metadata
    judge_ids = result_metadata.fetch("judge_trace_ids")
    assert_equal 1, judge_ids.size, "the result should collect exactly the one judge call made inside it"
    judge_trace = @tracer.traces.find { |trace| trace[:trace_id] == judge_ids.first }
    assert_equal "SupportJudge", judge_trace[:name], "a judge call should be traced under the judge name"
    assert_equal result_metadata.fetch("result_id"), judge_trace[:attributes]["eval.result_id"]

    verdict_id = metadata.fetch("judge_trace_ids").last
    verdict_trace = @tracer.traces.find { |trace| trace[:trace_id] == verdict_id }
    assert_equal "verdict", verdict_trace[:action]
    refute_includes verdict_trace[:attributes].keys, "eval.result_id",
                    "a verdict should not be attributed to the last result evaluated"
    refute_includes judge_ids, verdict_id
  end

  def test_extra_trace_keys_carry_a_callers_own_correlation_onto_its_traces
    keys = ActiveAgent::Evals::Correlation::DEFAULT_TRACE_KEYS + %w[tenant]
    correlation = ActiveAgent::Evals::Correlation.new(agent_name: "SupportAgent", tracer: @tracer.to_proc,
                                                      trace_keys: keys)
    correlation.with_run("run_id" => "run-1", "tenant" => "acme") { correlation.replay { nil } }

    assert_equal "acme", @tracer.traces.first[:attributes].fetch("eval.tenant")
  end

  def test_a_reopened_run_accumulates_onto_the_metadata_a_report_already_carries
    report = nil
    metadata = { "run_id" => "run-1" }
    @correlation.with_run(metadata) do |run|
      report = ActiveAgent::Evals::Runner.new(
        scenarios: [ scenario("lookup_1") ], models: [ spec("test-model") ], metadata: run,
        around_evaluation: @correlation, replay: ->(*) { replay(answer: "Order ABC-123 shipped on Monday.") }
      ).call
    end
    @correlation.with_run(metadata) { @correlation.judge("verdict") { nil } }

    assert_same metadata, report.metadata, "the run metadata should be the caller's own hash"
    assert_equal [ "trace-1" ], report.metadata.fetch("judge_trace_ids"),
                 "a verdict traced after the run should reach the report"
  end

  def test_a_replay_trace_id_never_lands_on_the_run
    @correlation.with_run("run_id" => "run-1") do |metadata|
      @correlation.replay { nil }
      assert_nil metadata["trace_id"], "a replay outside an evaluation should record no trace id on the run"
    end
  end

  def test_a_raising_replay_restores_the_enclosing_context
    outer = nil
    @correlation.with_run("run_id" => "outer") do |run|
      outer = @correlation.current
      assert_raises(IOError) do
        @correlation.around_evaluation(scenario("lookup_1"), spec("test-model")) do
          @correlation.replay { raise IOError, "synthetic failure" }
        end
      end
      assert_equal outer, @correlation.current, "the evaluation context should be restored after a failure"
      assert_equal "outer", run.fetch("run_id")
    end

    assert_nil @correlation.current, "the run context should be restored after the run"
  end

  def test_a_raising_run_restores_an_enclosing_run
    @correlation.with_run("run_id" => "outer") do
      assert_raises(IOError) do
        @correlation.with_run("run_id" => "inner") { raise IOError, "synthetic failure" }
      end

      assert_equal "outer", @correlation.current.fetch("run_id")
    end

    assert_nil @correlation.current
  end

  def test_a_run_mints_its_own_identity_when_the_caller_supplies_none
    first = @correlation.with_run { |metadata| metadata.fetch("run_id") }
    second = @correlation.with_run { |metadata| metadata.fetch("run_id") }

    refute_equal first, second
    assert_match(/\A[0-9a-f-]{36}\z/, first)
  end

  def test_without_a_tracer_identities_still_reach_the_results
    correlation = ActiveAgent::Evals::Correlation.new(agent_name: "SupportAgent")
    report = correlation.with_run("run_id" => "run-1") do |metadata|
      ActiveAgent::Evals::Runner.new(
        scenarios: [ scenario("lookup_1") ], models: [ spec("test-model") ], metadata: metadata,
        around_evaluation: correlation,
        replay: ->(*) { correlation.replay { replay(answer: "Order ABC-123 shipped on Monday.") } }
      ).call
    end

    metadata = report.results.first.replay.metadata
    assert_equal "run-1", metadata.fetch("run_id")
    refute_includes metadata.keys, "trace_id", "an untraced run records no trace id"
  end

  def test_a_plain_around_evaluation_lambda_adds_no_correlation
    seen = []
    wrapper = lambda do |scenario, spec, &evaluate|
      seen << [ scenario.key, spec.label ]
      evaluate.call
    end
    report = ActiveAgent::Evals::Runner.new(
      scenarios: [ scenario("lookup_1") ], models: [ spec("test-model") ], around_evaluation: wrapper,
      replay: ->(*) { replay(answer: "Order ABC-123 shipped on Monday.") }
    ).call

    assert_equal [ [ "lookup_1", "test-model" ] ], seen
    assert_equal 1, report.results.size
    assert_empty report.results.first.replay.metadata, "a plain wrapper should add no correlation of its own"
  end

  private

  def judge_calling(action)
    fake_judge do |_instructions, _prompt|
      @correlation.judge(action) { '{"score": 0.9}' }
    end
  end

  def run_evaluation(scenarios:, judge: nil)
    @correlation.with_run("run_id" => "run-1", "suite" => "support") do |metadata|
      yield metadata if block_given?
      ActiveAgent::Evals::Runner.new(
        scenarios: scenarios, models: [ spec("test-model") ], judge: judge, metadata: metadata,
        around_evaluation: @correlation,
        replay: ->(*) { @correlation.replay { replay(answer: "Order ABC-123 shipped on Monday.") } }
      ).call
    end
  end
end
