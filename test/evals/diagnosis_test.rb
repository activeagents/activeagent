# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsDiagnosisTest < ActiveSupport::TestCase
  include EvalsTestSupport

  ROSTER = %w[fetch_url find_records].freeze

  def diagnose(scenario:, replay:, scores: { "response_present" => 1.0 }, score: 1.0, available_tools: ROSTER)
    ActiveAgent::Evals::Diagnosis.call(
      scenario: scenario, replay: replay, scores: scores, score: score,
      available_tools: available_tools, threshold: 0.7
    )
  end

  def test_a_passing_result_has_no_fault
    assert_nil diagnose(scenario: scenario, replay: replay)
  end

  def test_a_failed_run_is_a_run_error_with_credential_guidance
    result = diagnose(scenario: scenario, replay: Replay.failed("No credentials configured for provider 'anthropic'"), score: nil)

    assert_equal "run_error", result.fault
    assert_match(/credentials/, result.recommendation)
  end

  def test_an_empty_answer_is_a_run_error
    result = diagnose(scenario: scenario, replay: replay(answer: ""), score: 0.0)

    assert_equal "run_error", result.fault
    assert_equal "empty answer", result.evidence["error"]
  end

  def test_a_tool_that_errored_outranks_every_other_fault
    result = diagnose(
      scenario: scenario(contains: [ "Alice" ]),
      replay: replay(answer: "I could not look that up.",
                     tool_calls: [ { "name" => "find_records", "error" => true, "detail" => "timeout", "arguments" => { "model" => "Provider" } } ]),
      score: 0.2
    )

    assert_equal "tool_error", result.fault
    assert_equal [ "find_records" ], result.evidence["tools"]
    assert_match(/timeout/, result.recommendation)
  end

  def test_an_agent_that_says_it_cannot_do_the_task_is_a_missing_capability
    result = diagnose(
      scenario: scenario,
      replay: replay(answer: "I don't have access to change history for providers, so I can't tell who edited it."),
      score: 0.4
    )

    assert_equal "missing_capability", result.fault
    assert_match(/None of the available tools/, result.recommendation)
    assert_match(/don't have access/, result.evidence["refusal"])
  end

  def test_a_negative_result_is_not_a_missing_capability
    result = diagnose(
      scenario: scenario,
      replay: replay(answer: "I checked the provider table and can't find any providers without a license on file; all 15,043 have one.")
    )

    assert_nil result
  end

  def test_a_refusal_names_the_expected_tool_when_the_agent_lacks_it
    result = diagnose(scenario: scenario(tools: [ "record_history" ]), replay: replay(answer: "I'm unable to retrieve edit history."), score: 0.4)

    assert_equal "missing_capability", result.fault
    assert_match(/record_history/, result.recommendation)
  end

  def test_the_agent_name_appears_in_the_wording
    result = ActiveAgent::Evals::Diagnosis.call(
      scenario: scenario, replay: replay(answer: "I cannot access that."), scores: {}, score: 0.1,
      available_tools: [], threshold: 0.7, agent_name: "Assistant"
    )

    assert_match(/\AAssistant said/, result.summary)
    assert_match(/Assistant has no tools/, result.recommendation)
  end

  def test_an_expected_tool_that_exists_but_was_not_called_points_at_the_instructions
    result = diagnose(scenario: scenario(tools: [ "find_records" ]), replay: replay, score: 0.5)

    assert_equal "expected_tool_not_called", result.fault
    assert_match(/available but the agent answered without calling any tool/, result.recommendation)
  end

  def test_an_expected_tool_the_agent_does_not_have_points_at_enabling_it
    result = diagnose(scenario: scenario(tools: [ "record_history" ]), replay: replay, score: 0.5)

    assert_equal "expected_tool_not_called", result.fault
    assert_equal [ "record_history" ], result.evidence["unavailable"]
  end

  def test_forbidden_and_missing_content_are_reported_in_that_order
    forbidden = diagnose(scenario: scenario(not_contains: [ "Alice" ], contains: [ "Bob" ]), replay: replay, score: 0.5)
    missing = diagnose(scenario: scenario(contains: [ "Bob" ]), replay: replay, score: 0.5)

    assert_equal "forbidden_content", forbidden.fault
    assert_equal "missing_content", missing.fault
    assert_equal [ "Bob" ], missing.evidence["missing"]
  end

  def test_a_low_score_with_no_other_evidence_is_low_quality_and_names_the_weakest_criterion
    result = diagnose(scenario: scenario, replay: replay, scores: { "response_present" => 1.0, "helpfulness" => 0.2 }, score: 0.6)

    assert_equal "low_quality", result.fault
    assert_match(/weakest on helpfulness/, result.summary)
  end
end
