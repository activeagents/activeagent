# frozen_string_literal: true

# The convention a host app follows, exercised on the dummy app: an eval is a
# test case in test/evals whose file ends in _eval.rb, so `rails test` never
# collects it, and `bin/rails active_agent:evals` runs it:
#
#   cd test/dummy && bin/rails active_agent:evals
#
# A host app's eval starts with `require "test_helper"`; the dummy app's
# helper is the gem's.
require_relative "../../../test_helper"
require "active_agent/evals/test_helper"
require_relative "../../../evals/support/eval_agents"

class OrdersAgentEval < ActiveAgent::Evals::TestCase
  test "finds an order with the lookup tool" do
    replay = run_eval EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask

    assert_answer_present replay
    assert_tool_called replay, "lookup_order", number: "ABC-123"
    assert_tools_succeeded replay
    assert_output_contains replay, "ABC-123"
    assert_eval_passes replay, expect: { tools: %w[lookup_order], contains: [ "shipped" ] }
  end

  test "the support suite passes as configured" do
    suite = File.expand_path("../../../evals/fixtures/support_suite.yml", __dir__)
    report = run_eval_suite(suite, groups: %w[orders]) do |scenario, _spec|
      EvalsTest::OrdersAgent.with(question: scenario.prompt).ask
    end

    assert_pass_rate report, at_least: 1.0
  end
end
