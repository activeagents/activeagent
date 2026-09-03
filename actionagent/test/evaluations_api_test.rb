# frozen_string_literal: true

require "test_helper"

# EvaluationRunnerService records the failure on the run and re-raises;
# letting that escape turned a persisted evaluation into an HTML 500 that
# the form displayed as a JSON parse error, and a resubmit then failed on
# the taken name (#381).
class EvaluationsApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  test "an evaluation whose run raises is still returned with its failed run" do
    exploding = ->(_evaluation) { raise "Judge-defined KPIs need provider credentials" }

    ActionAgent::EvaluationRunnerService.stub(:call, exploding) do
      post "/activeagents/api/evaluations", params: {
        evaluation: { agent_id: @agent.id, name: "KPIs", judge_kind: "judge_defined" }
      }
    end

    assert_response :created
    body = JSON.parse(response.body)
    latest = body.dig("evaluation", "latest_run")
    assert_equal "failed", latest["status"]
    assert_match(/provider credentials/, latest["error_message"])

    ActionAgent::EvaluationRunnerService.stub(:call, exploding) do
      post "/activeagents/api/evaluations/#{body.dig('evaluation', 'id')}/run"
    end

    assert_response :success
    assert_equal "failed", JSON.parse(response.body).dig("run", "status")
  end
end
