# frozen_string_literal: true

require "test_helper"

class EvalsStatisticsTest < ActiveSupport::TestCase
  Statistics = ActiveAgent::Evals::Statistics

  def test_percentile_is_the_value_at_the_nearest_rank
    durations = [ 400, 100, 300, 200 ]

    assert_equal 200, Statistics.percentile(durations, 50), "rank ceil(0.5 × 4) = 2, a value from the list rather than a mean of two"
    assert_equal 400, Statistics.percentile(durations, 95)
    assert_equal 100, Statistics.percentile(durations, 0)
    assert_equal 400, Statistics.percentile(durations, 100)
  end

  def test_percentile_of_twenty_values_takes_the_nineteenth_for_p95
    assert_equal 1_900, Statistics.percentile((1..20).map { |n| n * 100 }, 95)
    assert_equal 1_200, Statistics.percentile((1..12).map { |n| n * 100 }, 95), "rank ceil(11.4) = 12, where rounding would take the 11th"
  end

  def test_percentile_ignores_nils_and_is_nil_for_nothing
    assert_equal 700, Statistics.percentile([ nil, 700, nil ], 95)
    assert_nil Statistics.percentile([], 50)
    assert_nil Statistics.percentile([ nil ], 50)
  end
end
