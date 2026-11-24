# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsJudgeTest < ActiveSupport::TestCase
  include EvalsTestSupport

  def task
    scenario("order_1", "Where is order ABC-123?", group: "orders")
  end

  def test_the_judge_reads_a_rubric_past_the_first_300_characters_of_the_notes
    notes = ("The answer must list every open ticket with its due date. " * 6) + "Must not: invent a submitter name."
    rubric = ActiveAgent::Evals::Scenario.from_hash({ "key" => "k", "prompt" => "who submitted the review queue?", "notes" => notes })
    seen = []
    judge = fake_judge { |_instructions, prompt| seen << prompt; '{"score": 0.5, "recommendation": "ok"}' }

    judge.score_task(scenario: rubric, answer: "Nobody, apparently.")
    judge.recommend(scenario: rubric, replay: replay(answer: "Nobody, apparently."),
                    diagnosis: ActiveAgent::Evals::Diagnosis::Result.new(fault: "low_quality", summary: "s", recommendation: "r", evidence: {}))

    assert_operator notes.length, :>, 300
    assert seen.all? { |prompt| prompt.include?("Must not: invent a submitter name.") }, "the rubric's last clause never reached the judge"
  end

  def test_the_task_judge_is_shown_the_tool_calls_behind_an_answer
    seen = []
    judge = fake_judge { |_instructions, prompt| seen << prompt; '{"score": 0.9}' }
    calls = replay(answer: "There are 19 open issues.",
                   tool_calls: [ { name: "count_issues", arguments: { status: "open" }, detail: '{"count":19}' },
                                 { name: "find_users", arguments: {}, error: true } ]).tool_calls

    judge.score_task(scenario: task, answer: "There are 19 open issues.", tool_calls: calls)

    assert_includes seen.last, "Before answering, the assistant called these tools"
    assert_includes seen.last, %(- count_issues: {"status":"open"}\n  returned: {"count":19})
    assert_includes seen.last, "- find_users (errored): {}"
  end

  def test_the_task_judge_is_told_when_no_tool_was_called_and_nothing_when_it_was_not_given_the_calls
    seen = []
    judge = fake_judge { |_instructions, prompt| seen << prompt; '{"score": 0.9}' }

    judge.score_task(scenario: task, answer: "It shipped.", tool_calls: [])
    judge.score_task(scenario: task, answer: "It shipped.")

    assert_includes seen.first, "called these tools (their results are the data it had):\n(none)"
    assert_not_includes seen.last, "called these tools"
  end

  def test_a_long_tool_result_is_cut_short_for_the_judge
    seen = []
    judge = fake_judge { |_instructions, prompt| seen << prompt; '{"score": 0.9}' }
    calls = replay(answer: "Found them.", tool_calls: [ { name: "find_issues", arguments: {}, detail: "x" * 5_000 } ]).tool_calls

    judge.score_task(scenario: task, answer: "Found them.", tool_calls: calls)

    assert_operator seen.last.count("x"), :<=, ActiveAgent::Evals::Judge::TOOL_RESULT_LIMIT
  end

  def test_scores_are_json_numbers_including_exponent_notation
    { '{"score": 9e-2}' => 0.09, '{"score": 0.7}' => 0.7,
      '{"score": -0.2}' => 0.0, '{"score": 2}' => 1.0 }.each do |content, expected|
      judge = fake_judge { |*| content }

      assert_in_delta expected, judge.score_task(scenario: task, answer: "The order shipped."), 0.0001
      assert_in_delta expected, judge.score_criterion(criterion: { "key" => "quality" }, prompt: task.prompt, answer: "The order shipped."), 0.0001
    end
  end

  def test_malformed_or_non_numeric_scores_are_unscorable
    [ '{"score": "0.9"}', '{"score": true}', '{"score": null}', '{"score": {}}',
      '{"score": 0.9oops}', '{"score": 1e999}', '{"score": NaN}', "{}" ].each do |content|
      judge = fake_judge { |*| content }

      assert_nil judge.score_task(scenario: task, answer: "The order shipped."), content
    end
  end

  def test_fenced_json_scores_are_still_supported
    judge = fake_judge { |*| "```json\n{\"score\": 9e-2}\n```" }

    assert_in_delta 0.09, judge.score_task(scenario: task, answer: "The order shipped."), 0.0001
  end

  def test_unusable_recommendations_cannot_abort_any_report_format
    [ true, false, 42, [], [ "lookup_order" ], {}, { "name" => true }, { "name" => [] }, nil ].each do |suggestion|
      judge = fake_judge do |*|
        { score: 0.2, recommendation: "Check the order lookup.", suggested_tool: suggestion, instruction_change: [ "invalid" ] }.to_json
      end
      report = ActiveAgent::Evals::Runner.new(
        scenarios: [ task ], models: [ spec("test-model") ], judge: judge,
        replay: ->(*) { replay(answer: "The order may have shipped.") }
      ).call

      assert_equal "failed", report.results.first.status
      assert_nil report.results.first.suggested_tool, suggestion.inspect
      assert_nil report.results.first.diagnosis.dig("judge", "instruction_change")
      assert_equal "Check the order lookup.", report.results.first.recommendation
      assert_includes report.to_markdown, "Check the order lookup."
      assert_includes report.to_html, "Check the order lookup."
      assert_equal "failed", JSON.parse(report.to_json)["results"].first["status"]
    end
  end
end
