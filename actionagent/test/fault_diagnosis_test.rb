# frozen_string_literal: true

require "test_helper"

class ActionAgentFaultDiagnosisTest < ActiveSupport::TestCase
  ROSTER = [
    { name: "fetch_url", description: "Fetch a URL" },
    { name: "find_records", description: "Look up records" }
  ].freeze

  def scenario(expectations = {})
    ActionAgent::EvaluationScenario.new(key: "s_1", prompt: "Who changed the biography?", expectations: expectations)
  end

  def agent_run(output: "The biography was changed by Alice on Monday.", status: :complete, error_message: nil)
    ActionAgent::AgentRun.new(output: output, status: status, error_message: error_message, trace_id: "t")
  end

  def diagnose(scenario:, agent_run:, tool_calls: [], scores: { "response_present" => 1.0 }, score: 1.0, roster: ROSTER)
    ActionAgent::FaultDiagnosis.call(
      scenario: scenario, agent_run: agent_run, tool_calls: tool_calls,
      scores: scores, score: score, roster: roster, threshold: 0.7
    )
  end

  test "a passing result has no fault" do
    assert_nil diagnose(scenario: scenario, agent_run: agent_run)
  end

  test "a failed run is a run_error with credential guidance when credentials are missing" do
    result = diagnose(
      scenario: scenario,
      agent_run: agent_run(output: nil, status: :failed, error_message: "No credentials configured for provider 'anthropic'"),
      score: nil
    )

    assert_equal "run_error", result.fault
    assert_match(/Provider API Keys/, result.recommendation)
  end

  test "an empty answer is a run_error" do
    result = diagnose(scenario: scenario, agent_run: agent_run(output: ""), score: 0.0)

    assert_equal "run_error", result.fault
    assert_equal "empty output", result.evidence["error"]
  end

  test "a tool that errored outranks every other fault" do
    result = diagnose(
      scenario: scenario("contains" => [ "Alice" ]),
      agent_run: agent_run(output: "I could not look that up."),
      tool_calls: [ { "name" => "find_records", "error" => true, "detail" => "timeout", "arguments" => { "model" => "Physician" } } ],
      score: 0.2
    )

    assert_equal "tool_error", result.fault
    assert_equal [ "find_records" ], result.evidence["tools"]
    assert_match(/timeout/, result.recommendation)
  end

  test "an agent that says it cannot do the task is a missing_capability" do
    result = diagnose(
      scenario: scenario,
      agent_run: agent_run(output: "I don't have access to change history for providers, so I can't tell who edited it."),
      score: 0.4
    )

    assert_equal "missing_capability", result.fault
    assert_match(/None of the agent's tools/, result.recommendation)
    assert_match(/don't have access/, result.evidence["refusal"])
  end

  test "a refusal names the expected tool when the agent lacks it" do
    result = diagnose(
      scenario: scenario("tools" => [ "record_history" ]),
      agent_run: agent_run(output: "I'm unable to retrieve edit history."),
      score: 0.4
    )

    assert_equal "missing_capability", result.fault
    assert_match(/record_history/, result.recommendation)
  end

  test "an expected tool that exists but was not called points at the instructions" do
    result = diagnose(
      scenario: scenario("tools" => [ "find_records" ]),
      agent_run: agent_run,
      tool_calls: [],
      score: 0.5
    )

    assert_equal "expected_tool_not_called", result.fault
    assert_match(/available but the agent answered without calling any tool/, result.recommendation)
  end

  test "an expected tool the agent does not have points at enabling it" do
    result = diagnose(scenario: scenario("tools" => [ "record_history" ]), agent_run: agent_run, score: 0.5)

    assert_equal "expected_tool_not_called", result.fault
    assert_equal [ "record_history" ], result.evidence["unavailable"]
  end

  test "forbidden and missing content are reported in that order" do
    forbidden = diagnose(
      scenario: scenario("not_contains" => [ "Alice" ], "contains" => [ "Bob" ]),
      agent_run: agent_run, score: 0.5
    )
    missing = diagnose(scenario: scenario("contains" => [ "Bob" ]), agent_run: agent_run, score: 0.5)

    assert_equal "forbidden_content", forbidden.fault
    assert_equal "missing_content", missing.fault
    assert_equal [ "Bob" ], missing.evidence["missing"]
  end

  test "a low score with no other evidence is low_quality and names the weakest criterion" do
    result = diagnose(
      scenario: scenario,
      agent_run: agent_run,
      scores: { "response_present" => 1.0, "helpfulness" => 0.2 },
      score: 0.6
    )

    assert_equal "low_quality", result.fault
    assert_match(/weakest on helpfulness/, result.summary)
  end
end
