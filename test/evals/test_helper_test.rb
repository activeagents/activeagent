# frozen_string_literal: true

require "test_helper"
require "active_agent/evals/test_helper"
require_relative "support/eval_agents"

# The helper's own tests always run, so they include the helper rather than
# inherit the TestCase, whose tests are skipped unless evals are switched on.
class EvalsTestHelperTest < ActiveSupport::TestCase
  include ActiveAgent::Evals::TestHelper

  SUITE = File.expand_path("fixtures/support_suite.yml", __dir__)

  def with_env(values)
    saved = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def order_replay(number = "ABC-123")
    run_eval EvalsTest::OrdersAgent.with(question: "Where is order #{number}?").ask
  end

  def refusal_replay
    run_eval EvalsTest::OrdersAgent.with(question: "What is the weather?").ask
  end

  def failure_message
    error = assert_raises(Minitest::Assertion) { yield }
    error.message
  end

  test "run_eval returns the replay the assertions read" do
    replay = order_replay

    assert_answer_present replay
    assert_output_contains replay, "abc-123"
    assert_output_contains replay, "order \\w+-\\d+ is shipped"
    refute_output_contains replay, "cancelled"
    assert_tool_called replay, "lookup_order"
    assert_tool_called replay, :lookup_order, number: "ABC-123"
    refute_tool_called replay, "run_sql"
    assert_tools_succeeded replay
  end

  test "failure messages say what the agent did" do
    replay = refusal_replay

    message = failure_message { assert_tool_called replay, "lookup_order" }
    assert_match(/Expected the agent to call lookup_order \(no tools were called\)/, message)
    assert_match(/answer: I don't have access to that\./, message)

    message = failure_message { assert_output_contains replay, "shipped" }
    assert_match(/Expected the answer to contain "shipped"/, message)

    message = failure_message { assert_tool_called order_replay, "lookup_order", number: "ZZZ-1" }
    assert_match(/with \{"number" ?=> ?"ZZZ-1"\}, got \[\{"number" ?=> ?"ABC-123"\}\]/, message)

    message = failure_message { refute_tool_called order_replay, "lookup_order" }
    assert_match(/not to call lookup_order \(called: lookup_order\)/, message)

    message = failure_message { assert_tools_succeeded order_replay("BAD-2") }
    assert_match(/failed: lookup_order \(ArgumentError: no such order BAD-2\)/, message)

    message = failure_message { assert_answer_present order_replay("BAD-2") }
    assert_match(/got no answer\n  error: ArgumentError: no such order BAD-2/, message)
  end

  test "assert_eval_passes scores the replay against expectations and returns the result" do
    result = assert_eval_passes order_replay, expect: { tools: %w[lookup_order], contains: [ "ABC-123" ], not_contains: [ "password" ] }

    assert_kind_of ActiveAgent::Evals::Result, result
    assert result.passed?
    assert_equal 1.0, result.scores["expected_tools"]
    assert_equal 1.0, result.scores["expected_content"]
    assert_equal "mock-orders", result.model
    assert_equal "mock", result.provider
  end

  test "a failing eval reads as the fault and the fix" do
    message = failure_message { assert_eval_passes refusal_replay, expect: { tools: %w[lookup_order] } }

    assert_match(/\AEval failed: (missing_capability|expected_tool_not_called) — /, message)
    assert_match(/^Fix: /, message)
    assert_match(/^Scores: /, message)
    assert_match(/answer: I don't have access to that\./, message)
  end

  test "score_eval takes a prompt, criteria and a threshold without asserting" do
    result = score_eval order_replay, prompt: "Where is my order?", criteria: [ { "key" => "min_length", "type" => "min_length", "config" => { "chars" => 1_000 } } ],
                        threshold: 0.9

    assert result.failed?
    assert_equal "low_quality", result.fault
    assert_equal "Where is my order?", result.scenario.prompt
  end

  test "run_eval_suite replays a suite as configured and the pass rate gate reads the report" do
    report = run_eval_suite(SUITE, groups: %w[orders]) do |scenario, _spec|
      EvalsTest::OrdersAgent.with(question: scenario.prompt).ask
    end

    assert_kind_of ActiveAgent::Evals::Report, report
    assert_equal [ "as configured" ], report.summary_by_model.keys
    assert_equal 1, report.results.size, "the production-only scenario stays out unless asked for"
    assert report.results.first.passed?
    assert_pass_rate report, at_least: 1.0
  end

  test "a suite can run under named models and the gate names the scenarios that fell short" do
    report = run_eval_suite(SUITE, models: "mock/mock-fast", providers: %w[mock], include_production_only: true) do |scenario, spec|
      assert_equal "mock-fast", spec.model
      EvalsTest::OrdersAgent.with(question: scenario.prompt).ask
    end

    assert_equal [ "mock/mock-fast" ], report.summary_by_model.keys
    assert_equal 3, report.results.size
    # Under the plain mock provider nothing calls a tool, so the order
    # scenarios fail and the one without expectations passes.
    assert report.results.find { |result| result.scenario.key == "help_cancel" }.passed?
    # 1 of 3 is the report's 33.3%, which read as a percentage would fall short of a third.
    assert_pass_rate report, at_least: 1 / 3.0

    message = failure_message { assert_pass_rate report, at_least: 0.5 }
    assert_match(/mock\/mock-fast: 1\/3 .* passed, below 50%; failing: order_lookup \(\w+\), live_volume \(\w+\)/, message)
  end

  test "a suite block may answer with a replay, a hash or a string" do
    report = run_eval_suite(SUITE, keys: %w[help_cancel]) { |scenario, _spec| "Cancel it from the order page: #{scenario.key}" }

    assert_equal "Cancel it from the order page: help_cancel", report.results.first.replay.answer
    assert report.results.first.passed?
  end

  test "EVALS switches evals on" do
    { nil => false, "" => false, "0" => false, "false" => false, "off" => false, "1" => true, "true" => true, "yes" => true }.each do |value, expected|
      with_env("EVALS" => value) do
        assert_equal expected, ActiveAgent::Evals::TestHelper.enabled?, "EVALS=#{value.inspect}"
      end
    end
  end

  test "a TestCase skips its tests unless evals are switched on, so rails test never calls a model" do
    eval_case = Class.new(ActiveAgent::Evals::TestCase) do
      def self.name = "GuardedEval"

      def test_calls_the_agent
        assert_answer_present run_eval { "answered" }
      end
    end

    with_env("EVALS" => nil) do
      result = Minitest.run_one_method(eval_case, "test_calls_the_agent")
      assert result.skipped?, "expected a skip, got #{result.failure.inspect}"
      assert_match(%r{bin/rails test:evals}, result.failure.message)
    end

    with_env("EVALS" => "1") do
      result = Minitest.run_one_method(eval_case, "test_calls_the_agent")
      assert result.passed?, result.failure&.message
    end
  end

  test "the railtie's rake file defines test:evals" do
    require "rake"
    Rake::TaskManager.record_task_metadata = true
    app = Rake::Application.new
    Rake.with_application(app) { load File.expand_path("../../lib/tasks/active_agent/evals.rake", __dir__) }

    assert_match(%r{test/evals}, app["test:evals"].comment)
  end
end
