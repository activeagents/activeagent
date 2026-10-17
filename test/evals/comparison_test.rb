# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsComparisonTest < ActiveSupport::TestCase
  include EvalsTestSupport

  Comparison = ActiveAgent::Evals::Comparison
  Result = ActiveAgent::Evals::Result

  def gpt = (@gpt ||= spec("gpt-5-mini"))
  def qwen = (@qwen ||= spec("qwen3:8b"))
  def llama = (@llama ||= spec("llama3.2:3b"))

  # One result per scenario for +spec+: outcomes is a string of "p" (passed),
  # "f" (failed) and "e" (errored), one character per scenario s_0, s_1, ...
  # A "-" skips that scenario.
  def outcomes_of(spec, outcomes)
    outcomes.chars.each_with_index.filter_map do |outcome, index|
      next if outcome == "-"

      status = { "p" => "passed", "f" => "failed", "e" => "errored" }.fetch(outcome)
      Result.new(scenario: scenario("s_#{index}"), spec: spec, replay: replay, scores: {}, score: nil, status: status)
    end
  end

  def compare(*cohorts, **options)
    Comparison.new(results: cohorts.flat_map { |spec, outcomes| outcomes_of(spec, outcomes) }, models: cohorts.map(&:first), **options)
  end

  def test_each_model_reads_its_pass_rate_with_an_interval_around_it
    comparison = compare([ gpt, "p" * 36 + "f" * 6 ], [ qwen, "p" * 30 + "f" * 12 ])
    stats = comparison.models[gpt.label]

    assert_equal 42, stats["scenarios"]
    assert_equal 85.7, stats["pass_rate"]
    low, high = stats["interval"]
    assert_operator low, :<, 85.7
    assert_operator high, :>, 85.7
    # Near the normal approximation, 85.7 ± 1.96 × sqrt(p(1 - p) / n) × 100.
    assert_in_delta 75.1, low, 3.0
    assert_in_delta 96.3, high, 3.0
    # Every resampled mean is k/42, so every bound is one too.
    assert(stats["interval"].all? { |bound| (0..42).any? { |k| (k * 100.0 / 42).round(1) == bound } })
  end

  def test_the_ranking_reads_best_first_and_ties_keep_the_run_order
    comparison = compare([ qwen, "pfff" ], [ gpt, "ppfp" ], [ llama, "pfff" ])

    assert_equal [ gpt.label, qwen.label, llama.label ], comparison.ranking
  end

  def test_a_gap_well_beyond_the_noise_is_decisive_and_named
    comparison = compare([ qwen, "p" * 10 + "f" * 20 ], [ gpt, "p" * 30 ])
    pair = comparison.pairs.sole

    assert_equal [ gpt.label, qwen.label ], pair["models"], "the better ranked model comes first"
    assert_equal 30, pair["scenarios"]
    assert_equal 66.7, pair["difference"]
    assert pair["decisive"]
    assert_operator pair["interval"].first, :>, 0
    assert_match(/\Agpt-5-mini passes more scenarios than qwen3:8b, by 66\.7 points \(95% CI [\d.]+ to [\d.]+\)\.\z/, comparison.conclusion)
  end

  def test_a_gap_within_the_noise_is_not_decisive
    comparison = compare([ gpt, "ppppppfpff" ], [ qwen, "pppppfppff" ])
    pair = comparison.pairs.sole

    assert_equal 0.0, pair["difference"]
    assert_operator pair["interval"].first, :<, 0
    assert_operator pair["interval"].last, :>, 0
    assert_not pair["decisive"]
    assert_equal "The pairwise difference interval includes zero: the ranking is not decisive evidence of superiority.", comparison.conclusion
  end

  def test_pairs_are_compared_scenario_by_scenario
    # Both pass half their scenarios, on the same scenarios: every
    # per-scenario difference is zero, so a paired interval is exactly zero
    # while each model's own interval is wide.
    comparison = compare([ gpt, "pf" * 20 ], [ qwen, "pf" * 20 ])

    assert_equal [ 0.0, 0.0 ], comparison.pairs.sole["interval"]
    low, high = comparison.models[gpt.label]["interval"]
    assert_operator high - low, :>, 20
  end

  def test_three_models_give_three_pairs_and_one_sentence_for_all_of_them
    comparison = compare([ gpt, "ppppfpfppf" ], [ qwen, "pppfppfpff" ], [ llama, "ppfpfpfppf" ])

    assert_equal 3, comparison.pairs.size
    assert_equal "All 3 pairwise difference intervals include zero: the ranking is not decisive evidence of superiority.", comparison.conclusion
  end

  def test_a_decisive_pair_among_others_says_how_many_include_zero
    comparison = compare([ gpt, "p" * 30 ], [ qwen, "p" * 29 + "f" ], [ llama, "p" * 5 + "f" * 25 ])

    decisive = comparison.pairs.select { |pair| pair["decisive"] }.map { |pair| pair["models"] }
    assert_equal [ [ gpt.label, llama.label ], [ qwen.label, llama.label ] ], decisive
    assert_match(/\Agpt-5-mini passes more scenarios than llama3\.2:3b, by 83\.3 points .*\. qwen3:8b passes more scenarios than llama3\.2:3b, by 80\.0 points .*\. The other pairwise interval includes zero\.\z/,
                 comparison.conclusion)
  end

  def test_one_decisive_pair_among_three_says_the_other_two_include_zero
    comparison = compare([ gpt, "pppppppppffppppfpppf" ], [ qwen, "fpfpfppffppfppfpfppp" ], [ llama, "pffffpffffpfpfppffff" ])

    assert_equal [ false, true, false ], comparison.pairs.map { |pair| pair["decisive"] }
    assert_equal [ 0.0, 60.0 ], comparison.pairs.last["interval"], "a bound at zero includes zero"
    assert_match(/\Agpt-5-mini passes more scenarios than llama3\.2:3b, by 50\.0 points \(95% CI [\d.]+ to [\d.]+\)\. The other 2 pairwise intervals include zero\.\z/,
                 comparison.conclusion)
  end

  def test_a_model_ranked_first_overall_can_lose_decisively_on_the_shared_scenarios
    # gpt passes 40 scenarios qwen never ran and fails the 20 both ran, half
    # of which qwen passes: gpt ranks first, and loses where they overlap.
    comparison = compare([ gpt, "p" * 40 + "f" * 20 ], [ qwen, "-" * 40 + "pf" * 10 ])
    pair = comparison.pairs.sole

    assert_equal [ gpt.label, qwen.label ], pair["models"]
    assert_equal(-50.0, pair["difference"])
    assert_operator pair["interval"].last, :<, 0
    assert pair["decisive"]
    assert_match(/\Aqwen3:8b passes more scenarios than gpt-5-mini, by 50\.0 points \(95% CI [\d.]+ to [\d.]+\)\.\z/, comparison.conclusion)
  end

  def test_a_pair_is_compared_on_the_scenarios_both_models_ran
    comparison = compare([ gpt, "pppfpppfpp" ], [ qwen, "pppfp-----" ])
    pair = comparison.pairs.sole

    assert_equal 5, pair["scenarios"]
    assert_equal 0.0, pair["difference"], "on the five shared scenarios the two agree"
    assert_equal 5, comparison.models[qwen.label]["scenarios"]
  end

  def test_an_errored_result_counts_as_not_passed
    comparison = compare([ gpt, "ppee" ], [ qwen, "ppff" ])

    assert_equal 50.0, comparison.models[gpt.label]["pass_rate"]
    assert_equal 0.0, comparison.pairs.sole["difference"]
  end

  def test_too_few_scenarios_give_no_interval_and_say_so
    comparison = compare([ gpt, "p" ], [ qwen, "f" ])

    assert_nil comparison.models[gpt.label]["interval"]
    assert_nil comparison.pairs.sole["interval"]
    assert_not comparison.pairs.sole["decisive"]
    assert_equal "The models share too few scenarios to compare.", comparison.conclusion
  end

  def test_a_pair_without_enough_shared_scenarios_is_named_beside_the_others
    comparison = compare([ gpt, "ppfpfp" ], [ qwen, "pfppfp" ], [ llama, "-----p" ])

    assert_equal "The pairwise difference interval includes zero: the ranking is not decisive evidence of superiority. " \
                 "2 pairs share too few scenarios to compare.", comparison.conclusion
  end

  def test_a_model_with_no_results_has_no_rate_and_ranks_last
    comparison = Comparison.new(results: outcomes_of(gpt, "pp"), models: [ qwen, gpt ])

    assert_equal [ 0, nil, nil ], comparison.models[qwen.label].values_at("scenarios", "pass_rate", "interval")
    assert_equal [ gpt.label, qwen.label ], comparison.ranking
  end

  def test_repeated_results_for_a_scenario_count_as_one_scenario
    results = outcomes_of(gpt, "pf") + outcomes_of(gpt, "pp") + outcomes_of(qwen, "pp")
    comparison = Comparison.new(results: results, models: [ gpt, qwen ])

    assert_equal 2, comparison.models[gpt.label]["scenarios"]
    assert_equal 75.0, comparison.models[gpt.label]["pass_rate"], "s_0 passed twice, s_1 once in two"
  end

  def test_the_same_results_give_the_same_intervals_and_the_seed_is_recorded
    cohorts = [ [ gpt, "ppfpfpppfp" * 20 ], [ qwen, "pfpfpfppff" * 20 ] ]

    # Few resamples over many scenarios, so the bounds move with the seed.
    assert_equal compare(*cohorts, resamples: 50).to_h, compare(*cohorts, resamples: 50).to_h
    assert_not_equal compare(*cohorts, resamples: 50, seed: 1).models, compare(*cohorts, resamples: 50, seed: 2).models
    method = compare(*cohorts, seed: 7, resamples: 200).to_h["method"]
    assert_equal({ "statistic" => "pass rate", "interval" => "percentile bootstrap", "unit" => "scenario",
                   "resamples" => 200, "confidence" => 0.95, "seed" => 7 }, method)
  end

  def test_a_lower_confidence_gives_a_narrower_interval
    cohorts = [ [ gpt, "p" * 20 + "f" * 10 ], [ qwen, "p" * 15 + "f" * 15 ] ]
    wide = compare(*cohorts).models[gpt.label]["interval"]
    narrow = compare(*cohorts, confidence: 0.5).models[gpt.label]["interval"]

    assert_operator narrow.last - narrow.first, :<, wide.last - wide.first
    assert_includes compare(*cohorts, confidence: 0.5).conclusion.to_s + compare([ gpt, "p" * 30 ], [ qwen, "f" * 30 ], confidence: 0.9).conclusion, "(90% CI"
  end

  def test_a_single_model_has_no_pairs_and_no_conclusion
    comparison = compare([ gpt, "ppf" ])

    assert_empty comparison.pairs
    assert_nil comparison.conclusion
  end
end
