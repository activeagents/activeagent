# frozen_string_literal: true

require "test_helper"

# One vocabulary for passes, scores and costs across the reports, the
# diagnosis and the dashboard (whose evalFormat.mjs copies these rules).
class EvalsFormatTest < ActiveSupport::TestCase
  Format = ActiveAgent::Evals::Format

  def test_a_fraction_carries_its_percent_and_nothing_scored_is_a_dash
    assert_equal "14/16 · 88%", Format.passes(14, 16)
    assert_equal "14/16 (88%)", Format.passes(14, 16, style: :markdown)
    assert_equal "0/3 · 0%", Format.passes(0, 3)
    assert_equal "—", Format.passes(0, 0)
    assert_equal "—", Format.passes(nil, nil)
  end

  def test_percentages_round_half_up_to_a_whole_number
    assert_equal "88%", Format.percent(0.875)
    assert_equal "15%", Format.percent(0.145), "14.499999999999998 is 14.5"
    assert_equal "1/8 · 13%", Format.passes(1, 8)
    assert_equal "100%", Format.percent(1)
    assert_equal "0%", Format.percent(0)
    assert_equal "—", Format.percent(nil)
    assert_equal "—", Format.percent("")
  end

  def test_scores_and_the_threshold_read_as_percents
    assert_equal "93%", Format.score(0.93)
    assert_equal "60%", Format.score(0.6)
    assert_equal "pass ≥ 70%", Format.threshold(0.7)
    assert_equal "—", Format.score(nil)
  end

  def test_money_has_four_decimals_six_below_a_tenth_of_a_cent_and_a_tilde_when_estimated
    assert_equal "$0.0243", Format.money(0.0243)
    assert_equal "$0.000697", Format.money(0.000697)
    assert_equal "$0.00", Format.money(0)
    assert_equal "$0.00", Format.money(0.0)
    assert_equal "~$0.0243", Format.money(0.0243, estimated: true)
    assert_equal "$12.3457", Format.money(12.34567)
    assert_equal "—", Format.money(nil)
  end

  def test_the_cost_title_shows_the_working_and_marks_a_fallback_rate
    rate = { "input" => 5, "output" => 30, "source" => "catalog" }
    assert_equal "estimated: 2,328 in × $5.00/M + 423 out × $30.00/M · catalog rate",
                 Format.cost_title(input_tokens: 2328, output_tokens: 423, rate: rate)
    assert_equal "estimated: 100 in × $0.15/M + 20 out × $0.60/M · pattern rate (fallback rate)",
                 Format.cost_title(input_tokens: 100, output_tokens: 20, rate: { input: 0.15, output: 0.6, source: "pattern" })
    assert_equal "estimated: 1,000,000 in × $1.00/M + 0 out × $4.00/M · default rate (fallback rate)",
                 Format.cost_title(input_tokens: 1_000_000, output_tokens: 0, rate: { "input" => 1.0, "output" => 4.0, "source" => "default" })
    assert_equal "estimated from tokens × model rates", Format.cost_title(input_tokens: 10, output_tokens: 2, rate: nil)
    assert_equal "$0.075/M", Format.per_million(0.075)
  end

  def test_the_legend_is_the_one_the_dashboard_shows
    assert_equal "~ estimated from tokens × model rates", Format::LEGEND
  end
end
