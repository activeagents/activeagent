# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsScorerTest < ActiveSupport::TestCase
  include EvalsTestSupport

  CRITERIA = [
    { "key" => "response_present", "type" => "response_present" },
    { "key" => "response_length", "type" => "min_length", "config" => { "chars" => 20 } },
    { "key" => "latency", "type" => "max_latency_ms", "config" => { "ms" => 1000 } },
    { "key" => "token_budget", "type" => "token_budget", "config" => { "output_tokens" => 100 } },
    { "key" => "mentions_alice", "type" => "contains", "config" => { "pattern" => "alice" } },
    { "key" => "no_apology", "type" => "not_contains", "config" => { "pattern" => "sorry" } }
  ].freeze

  def scorer(criteria: CRITERIA, judge: nil)
    ActiveAgent::Evals::Scorer.new(criteria: criteria, judge: judge)
  end

  def test_rule_criteria_score_the_replay
    scores = scorer.score(scenario, replay(answer: "Alice changed it on Monday.", duration_ms: 2000, output_tokens: 50))

    assert_equal 1.0, scores["response_present"]
    assert_equal 1.0, scores["response_length"]
    assert_equal 0.5, scores["latency"]
    assert_equal 1.0, scores["token_budget"]
    assert_equal 1.0, scores["mentions_alice"]
    assert_equal 1.0, scores["no_apology"]
  end

  def test_partial_credit_below_a_length_and_above_a_token_budget
    scores = scorer.score(scenario, replay(answer: "Ten chars.", output_tokens: 200))

    assert_equal 0.5, scores["response_length"]
    assert_equal 0.5, scores["token_budget"]
  end

  def test_an_empty_answer_scores_zero_on_every_criterion
    scores = scorer.score(scenario, replay(answer: ""))

    assert scores.values.all?(0.0)
  end

  def test_expectations_add_their_own_keys
    scores = scorer(criteria: []).score(
      scenario(tools: [ "find_records" ], contains: %w[Alice Monday Tuesday], not_contains: [ "Bob" ]),
      replay(answer: "Alice changed it on Monday.", tool_calls: [ { "name" => "find_records" }, { "name" => "fetch_url", "error" => true } ])
    )

    assert_equal 1.0, scores["expected_tools"]
    assert_equal 0.667, scores["expected_content"]
    assert_equal 1.0, scores["forbidden_content"]
    assert_equal 0.0, scores["tools_succeeded"]
  end

  def test_a_wrong_tool_that_succeeded_is_not_credited_as_a_success
    scores = scorer(criteria: []).score(
      scenario(tools: [ "find_records" ]),
      replay(answer: "Alice changed it.", tool_calls: [ { "name" => "fetch_url" } ])
    )

    assert_equal 0.0, scores["expected_tools"]
    assert_nil scores["tools_succeeded"], "a tool the scenario did not ask for is not evidence of the task"
  end

  def test_any_successful_tool_counts_when_the_scenario_names_none
    scores = scorer(criteria: []).score(scenario, replay(tool_calls: [ { "name" => "fetch_url" } ]))

    assert_equal 1.0, scores["tools_succeeded"]
  end

  def test_an_llm_judge_criterion_asks_the_judge_and_is_nil_without_one
    judge = fake_judge { |_instructions, prompt| prompt.include?("Criterion: Is it helpful?") ? '{"score": 0.8}' : "?" }
    criteria = [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is it helpful?" } } ]

    assert_equal 0.8, scorer(criteria: criteria, judge: judge).score(scenario, replay)["quality"]
    assert_nil scorer(criteria: criteria).score(scenario, replay)["quality"]
  end

  def test_mean_ignores_unscorable_criteria
    assert_equal 0.75, ActiveAgent::Evals::Scorer.mean("a" => 1.0, "b" => 0.5, "c" => nil)
    assert_nil ActiveAgent::Evals::Scorer.mean("c" => nil)
  end

  def test_a_pattern_matches_as_a_substring_before_it_is_tried_as_a_regex
    matches = ActiveAgent::Evals::Scorer.method(:matches_pattern?)

    assert matches.call("costs $5 (approx", "(approx"), "an invalid regex is still a substring"
    assert matches.call("It costs $5 today", "$5"), "a regex anchor is literal when the text contains it"
    assert matches.call("1,060 (locally) have none", "1,060 (locally)")
    assert matches.call("Alice changed it", "alice|bob"), "a regex still matches"
    assert_not matches.call("Dr. Smith is here", "redacted")
  end

  def test_a_pathological_regex_times_out_instead_of_stalling_the_evaluation
    assert_not ActiveAgent::Evals::Scorer.matches_pattern?("#{'a' * 40}!", "(a+)+\\1$")
  end
end
