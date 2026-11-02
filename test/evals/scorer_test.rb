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

  JUDGED = [ { "key" => "quality", "type" => "llm_judge", "config" => { "prompt" => "Is it helpful?" } } ].freeze

  def scorer(criteria: CRITERIA, judge: nil, **options)
    ActiveAgent::Evals::Scorer.new(criteria: criteria, judge: judge, **options)
  end

  # A scorer with one llm_judge criterion whose judge tallies its calls in `calls`.
  def judged_scorer(calls, criteria: JUDGED, **options)
    scorer(criteria: criteria, judge: counting_judge(calls), **options)
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
      scenario(tools: [ "find_tickets" ], contains: %w[Alice Monday Tuesday], not_contains: [ "Bob" ]),
      replay(answer: "Alice changed it on Monday.", tool_calls: [ { "name" => "find_tickets" }, { "name" => "fetch_url", "error" => true } ])
    )

    assert_equal 1.0, scores["expected_tools"]
    assert_equal 0.667, scores["expected_content"]
    assert_equal 1.0, scores["forbidden_content"]
    assert_equal 0.0, scores["tools_succeeded"]
  end

  def test_a_wrong_tool_that_succeeded_is_not_credited_as_a_success
    scores = scorer(criteria: []).score(
      scenario(tools: [ "find_tickets" ]),
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

  def test_a_replay_that_missed_an_expected_tool_is_judged_only_by_default
    task = scenario(tools: [ "find_tickets" ])
    missed = replay(answer: "Alice changed it on Monday.", tool_calls: [])
    calls = Hash.new(0)

    gated_scorer = judged_scorer(calls, judge_failed_expectations: false)
    assert_equal false, gated_scorer.judge_failed_expectations
    assert_equal true, scorer.judge_failed_expectations

    gated = gated_scorer.score(task, missed)
    assert_equal 0.0, gated["expected_tools"]
    assert_nil gated["quality"]
    assert_equal 0, calls["score_criterion"], "a replay that failed an expectation is not worth a judge call"

    judged = judged_scorer(calls).score(task, missed)
    assert_equal 0.9, judged["quality"]
    assert_equal 1, calls["score_criterion"]
  end

  def test_a_replay_meeting_every_expectation_is_judged_whether_or_not_failed_ones_are
    task = scenario(tools: [ "find_tickets" ], contains: %w[Alice Monday], not_contains: [ "Bob" ])
    met = replay(answer: "Alice changed it on Monday.", tool_calls: [ { "name" => "find_tickets" } ])

    [ true, false ].each do |flag|
      calls = Hash.new(0)
      scores = judged_scorer(calls, judge_failed_expectations: flag).score(task, met)

      assert_equal 0.9, scores["quality"], "judge_failed_expectations: #{flag}"
      assert_equal({ "score_criterion" => 1 }, calls)
    end
  end

  def test_a_failed_tool_call_a_forbidden_phrase_or_a_missing_pattern_gates_the_judge
    calls = Hash.new(0)
    gated = judged_scorer(calls, judge_failed_expectations: false)

    errored = gated.score(scenario(tools: [ "find_tickets" ]), replay(tool_calls: [ { "name" => "find_tickets", "error" => true } ]))
    forbidden = gated.score(scenario(not_contains: [ "Alice" ]), replay)
    partial = gated.score(scenario(contains: %w[Alice Tuesday]), replay)

    assert_equal 0.0, errored["tools_succeeded"]
    assert_nil errored["quality"]
    assert_equal 0.0, forbidden["forbidden_content"]
    assert_nil forbidden["quality"]
    assert_equal 0.5, partial["expected_content"]
    assert_nil partial["quality"]
    assert_empty calls
  end

  def test_a_scenario_with_no_expectations_is_judged_and_a_blank_answer_never_is
    calls = Hash.new(0)
    gated = judged_scorer(calls, criteria: CRITERIA + JUDGED, judge_failed_expectations: false)

    assert_equal 0.9, gated.score(scenario, replay)["quality"]
    assert_equal({ "score_criterion" => 1 }, calls)

    blank = gated.score(scenario(tools: [ "find_tickets" ]), replay(answer: ""))
    assert blank.values.all?(0.0)
    assert_equal({ "score_criterion" => 1 }, calls, "a blank answer scores 0.0 without asking the judge")
  end

  def test_expectations_are_met_when_every_expectation_key_present_is_full
    met = ActiveAgent::Evals::Scorer.method(:expectations_met?)

    assert met.call({})
    assert met.call("quality" => 0.0, "expected_tools" => 1.0, "tools_succeeded" => 1.0)
    assert_not met.call("expected_content" => 0.5)
    assert_not met.call("forbidden_content" => 0.0)
    assert_equal %w[expected_tools expected_content forbidden_content tools_succeeded], ActiveAgent::Evals::Scorer::EXPECTATION_KEYS
  end

  def test_scores_keep_their_key_order_whether_or_not_failed_expectations_are_judged
    criteria = CRITERIA.first(3) + JUDGED + CRITERIA.last(3)
    task = scenario(tools: [ "find_tickets" ], contains: %w[Alice Monday], not_contains: [ "Bob" ])
    missed = replay(answer: "Alice changed it.", tool_calls: [ { "name" => "find_tickets" }, { "name" => "fetch_url", "error" => true } ])
    expected = %w[response_present response_length latency quality token_budget mentions_alice no_apology
                  expected_tools expected_content forbidden_content tools_succeeded]

    [ true, false ].each do |flag|
      scores = judged_scorer(Hash.new(0), criteria: criteria, judge_failed_expectations: flag).score(task, missed)

      assert_equal expected, scores.keys, "judge_failed_expectations: #{flag}"
      assert_equal expected, JSON.parse(scores.to_json).keys
    end
  end

  def test_a_pattern_matches_as_a_substring_before_it_is_tried_as_a_regex
    matches = ActiveAgent::Evals::Scorer.method(:matches_pattern?)

    assert matches.call("costs $5 (approx", "(approx"), "an invalid regex is still a substring"
    assert matches.call("It costs $5 today", "$5"), "a regex anchor is literal when the text contains it"
    assert matches.call("40 (sample) have none", "40 (sample)")
    assert matches.call("Alice changed it", "alice|bob"), "a regex still matches"
    assert_not matches.call("Dr. Smith is here", "redacted")
  end

  def test_a_pathological_regex_times_out_instead_of_stalling_the_evaluation
    assert_not ActiveAgent::Evals::Scorer.matches_pattern?("#{'a' * 40}!", "(a+)+\\1$")
  end
end
