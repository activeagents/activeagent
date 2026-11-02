# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"
require "active_agent/evals/minitest"

class EvalsMinitestAssertionsTest < ActiveSupport::TestCase
  include EvalsTestSupport
  include ActiveAgent::Evals::Minitest::Assertions

  def test_a_report_whose_gates_are_met_passes
    assert_meets_pass_gates(passing_report)
    assert_meets_pass_gates(gated_report, LENIENT)
  end

  def test_an_unmet_gate_fails_with_the_check_message
    error = assert_raises(Minitest::Assertion) { assert_meets_pass_gates(gated_report) }

    assert_equal ActiveAgent::Evals::GateCheck.new(gated_report).message, error.message
    assert error.message.start_with?("2 of 7 pass gates not met\n- Order support · gpt-5-mini"), error.message
  end

  def test_a_given_message_wins
    error = assert_raises(Minitest::Assertion) { assert_meets_pass_gates(gated_report, nil, "the support desk suite regressed") }

    assert_equal "the support desk suite regressed", error.message
  end
end
