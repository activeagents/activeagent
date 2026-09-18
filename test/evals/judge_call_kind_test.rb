# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

# A judge serves three calls — scoring an answer, recommending a fix, and
# writing the run's verdict — and a host routinely needs to tell them apart, to
# trace them separately or to grade with a cheaper model than it writes the
# verdict with. Before `kind:` the only signal was the `instructions` string, so
# hosts matched on the gem's own constants and a reworded constant mislabelled
# them silently rather than failing.
class EvalsJudgeCallKindTest < ActiveSupport::TestCase
  include EvalsTestSupport

  # A judge whose block accepts the kind, recording what it was told.
  def judging_judge(reply, kinds)
    ActiveAgent::Evals::Judge.new(label: "judge") do |instructions:, prompt:, kind:|
      _ = instructions, prompt
      kinds << kind
      reply
    end
  end

  def diagnosis
    ActiveAgent::Evals::Diagnosis::Result.new(fault: "low_quality", summary: "s", recommendation: "r", evidence: {})
  end

  def test_scoring_calls_are_named_score
    kinds = []
    judge = judging_judge('{"score": 0.5}', kinds)

    judge.score_task(scenario: scenario, answer: "Alice did.")
    judge.score_criterion(criterion: { "key" => "tone" }, prompt: "p", answer: "a")

    assert_equal [ :score, :score ], kinds
  end

  def test_a_recommendation_is_named_recommend
    kinds = []
    judge = judging_judge('{"recommendation": "say more"}', kinds)

    judge.recommend(scenario: scenario, replay: replay, diagnosis: diagnosis)

    assert_equal [ :recommend ], kinds
  end

  def test_the_verdict_is_named_verdict
    kinds = []
    judge = judging_judge('{"winner": "gpt-5.5", "rationale": "cheapest"}', kinds)

    judge.verdict({ "gpt-5.5" => { "pass_rate" => 90 } })

    assert_equal [ :verdict ], kinds
  end

  # The block signature is public API. A judge written before `kind:` existed
  # takes exactly two keywords, and passing a third raises ArgumentError — which
  # `ask` catches and reports as a judge failure, silently degrading the run to
  # rule scoring. So the keyword must not reach such a block at all.
  def test_a_block_that_does_not_accept_the_kind_never_receives_it
    seen = []
    judge = ActiveAgent::Evals::Judge.new(label: "judge") do |instructions:, prompt:|
      _ = instructions, prompt
      seen << :called
      '{"score": 0.5}'
    end

    assert_equal 0.5, judge.score_task(scenario: scenario, answer: "Alice did.")
    assert_equal [ :called ], seen, "the legacy two-keyword block was not called"
  end

  def test_a_block_collecting_keywords_receives_the_kind
    seen = {}
    judge = ActiveAgent::Evals::Judge.new(label: "judge") do |**options|
      seen = options
      '{"score": 0.5}'
    end

    judge.score_task(scenario: scenario, answer: "Alice did.")

    assert_equal :score, seen[:kind]
    assert seen.key?(:instructions) && seen.key?(:prompt)
  end
end
