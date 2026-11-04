# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

# Regexes for the count or share a seeded scenario expects in an answer, as
# Scorer.matches_pattern? tries them.
class EvalsPatternsTest < ActiveSupport::TestCase
  include EvalsTestSupport

  Patterns = ActiveAgent::Evals::Patterns
  Scorer = ActiveAgent::Evals::Scorer

  def test_a_number_matches_the_figure_on_its_own
    assert_matches Patterns.number(10), "10 sessions", "Sessions: 10", "(10)", "There were 10.", "10\n"
    assert_matches Patterns.number(3), "3 of 4 tickets"
    assert_matches Patterns.number(0), "0 open tickets"
  end

  def test_a_number_does_not_match_inside_a_longer_number_a_date_a_time_or_a_range
    assert_no_matches Patterns.number(10), "2026-10-01", "10/1", "10:00", "1-10", "10-12", "110", "10.5", "10,000", "0.10", "1,010", "10%", "10 %"
    assert_no_matches Patterns.number(0), "10"
  end

  def test_a_number_does_not_match_a_day_beside_its_month_a_dashed_range_or_a_ratio
    assert_no_matches Patterns.number(12), "Oct 12, 2026", "Sept. 12", "October 12", "on 12 October", "12th of October", "12 Oct",
                      "12–22", "12—22", "12/22"
    assert_matches Patterns.number(12), "12 decision-tree sessions", "12 marked", "12 may drop off", "Omar saw 12", "12 of 22"
  end

  def test_a_count_is_read_as_a_whole_number_from_its_text
    assert_equal Patterns.number(3), Patterns.number("3")
    assert_raises(ArgumentError) { Patterns.number(10.0) }
  end

  def test_a_share_matches_the_whole_one_or_two_decimal_percent_with_an_optional_space
    assert_matches Patterns.share(3, 4), "75%", "75 %", "75.0%", "75.0 %", "75.00%", "(75%)", "75% of"
    assert_no_matches Patterns.share(3, 4), "175%", "7.5%", "75.5%", "75", "0.75"
  end

  def test_a_share_rounds_the_whole_percent_half_up_and_the_decimals_to_their_places
    assert_matches Patterns.share(1, 3), "33%", "33.3%", "33.33%"
    assert_no_matches Patterns.share(1, 3), "33.333%", "33.34%", "3%"
    assert_matches Patterns.share(12, 22), "55%", "54.5%", "54.55%"
    assert_matches Patterns.share(2, 3), "67%", "66.7%"
    assert_no_matches Patterns.share(2, 3), "66%"
    assert_matches Patterns.share(1, 8), "13%", "12.5%"
    assert_no_matches Patterns.share(1, 8), "12%"
    assert_matches Patterns.share(4, 4), "100%", "100.0%"
    assert_matches Patterns.share(0, 4), "0%", "0.0%"
  end

  def test_a_count_that_is_not_a_whole_number_or_a_share_that_is_not_a_fraction_raises
    error = assert_raises(ArgumentError) { Patterns.share(1, 0) }
    assert_equal "total must be positive", error.message
    assert_equal "total must be positive", assert_raises(ArgumentError) { Patterns.share(1, -1) }.message
    assert_equal "count must be zero or positive", assert_raises(ArgumentError) { Patterns.share(-1, 4) }.message
    assert_raises(ArgumentError) { Patterns.share(5, 4) }
    assert_raises(ArgumentError) { Patterns.number(-1) }
    assert_raises(ArgumentError) { Patterns.number(1.5) }
    assert_raises(ArgumentError) { Patterns.share("a", 2) }
  end

  def test_a_scenario_expects_the_figures_its_data_implies
    scenario = Scenario.from_hash({
      "key" => "open_tickets",
      "prompt" => "How many tickets are open?",
      "expect" => { "contains" => [ Patterns.number(3), Patterns.share(3, 4) ] }
    })
    scorer = Scorer.new(criteria: [])

    assert_equal 1.0, scorer.score(scenario, replay(answer: "3 of 4 tickets (75%) are open"))["expected_content"]
    assert_equal 0.0, scorer.score(scenario, replay(answer: "30 of 40 tickets (7.5%)"))["expected_content"]
    assert_equal 0.0, scorer.score(scenario, replay(answer: "3% of 40 tickets"))["expected_content"], "a percentage is not the count"
  end

  private

  # Each text matches `pattern` both as a Regexp and through the Scorer.
  def assert_matches(pattern, *texts)
    texts.each do |text|
      assert_match Regexp.new(pattern), text
      assert Scorer.matches_pattern?(text, pattern), "Scorer.matches_pattern? should match #{text.inspect}"
    end
  end

  def assert_no_matches(pattern, *texts)
    texts.each do |text|
      assert_no_match Regexp.new(pattern), text
      assert_not Scorer.matches_pattern?(text, pattern), "Scorer.matches_pattern? should not match #{text.inspect}"
    end
  end
end
