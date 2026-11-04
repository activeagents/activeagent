# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsResultTest < ActiveSupport::TestCase
  include EvalsTestSupport

  Result = ActiveAgent::Evals::Result

  def result(**attributes)
    Result.new(scenario: scenario, spec: spec("gpt-5-mini"), replay: replay, scores: { "response_present" => 1.0 },
               score: 1.0, status: "passed", **attributes)
  end

  def test_a_result_built_without_a_trial_is_the_first
    assert_equal 1, result.trial
    assert_equal 1, Result.new.trial
  end

  def test_a_result_keeps_the_trial_it_was_built_with
    assert_equal 2, Result.new(trial: 2).trial
    assert_equal 3, result(trial: 3).trial
  end

  def test_to_h_carries_the_trial_after_the_model
    hash = result.to_h

    assert_equal 1, hash["trial"]
    assert_equal %w[provider model trial status], hash.keys[4, 4]
    assert_equal 2, result(trial: 2).to_h["trial"]
  end
end
