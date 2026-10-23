# frozen_string_literal: true

# The convention a host app follows, exercised on the dummy app: an eval is
# an ordinary test under test/evals; `rails test` collects it and skips it,
# and `bin/rails test:evals` runs it:
#
#   cd test/dummy && bin/rails test:evals
#   cd test/dummy && bin/rails test            # 2 skips, no model called
#
# The gem's own runner leaves test/dummy/test/evals out (bin/test, Rakefile):
# this is the host app's sample, not a test of the gem.
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
