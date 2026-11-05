# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"
require "active_agent/evals/rspec"

class EvalsRSpecMatcherTest < ActiveSupport::TestCase
  include EvalsTestSupport
  include ActiveAgent::Evals::RSpec

  def test_the_matcher_is_built_without_rspec_and_defines_none
    assert_nil defined?(::RSpec::Matchers), "rspec is not in the bundle"
    assert_nil defined?(::RSpec), "the module must not define a top-level RSpec"
    matcher = meet_its_pass_gates

    assert_instance_of ActiveAgent::Evals::RSpec::MeetItsPassGates, matcher
    assert_not matcher.diffable?
    assert_not matcher.supports_block_expectations?
  end

  def test_it_matches_a_report_whose_gates_are_met_and_fails_with_the_check_message
    matcher = meet_its_pass_gates

    assert matcher.matches?(passing_report)
    assert_not matcher.matches?(gated_report)
    assert_equal ActiveAgent::Evals::GateCheck.new(gated_report).message, matcher.failure_message
    assert_equal "meet its pass gates", matcher.description
  end

  def test_the_negated_message_lists_every_gate
    matcher = meet_its_pass_gates
    report = passing_report
    assert matcher.matches?(report)
    lines = matcher.failure_message_when_negated.lines(chomp: true)

    assert_equal "expected the report not to meet its pass gates, but every gate was met:", lines.first
    assert_equal report.gates.map(&:to_s), lines.drop(1)
    assert_equal 5, report.gates.size, "the two groups with a pass and the two All rows"
  end

  def test_given_bars_are_the_ones_checked_and_name_the_description
    matcher = meet_its_pass_gates(LENIENT)

    assert matcher.matches?(gated_report)
    assert_equal "meet the given pass gates", matcher.description

    strict = meet_its_pass_gates(PassThresholds.default)
    assert_not strict.matches?(Report.new(results: gated_results, models: models))
    assert_equal ActiveAgent::Evals::GateCheck.new(gated_report, PassThresholds.default).message, strict.failure_message
  end
end
