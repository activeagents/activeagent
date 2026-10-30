# frozen_string_literal: true

require "test_helper"

# Shareable evaluation links: /evaluations/:id, /evaluations/:id/runs/:run_id
# and /evaluations/:id/runs/:run_id/results/:result_id open the dashboard on
# that evaluation, run or scenario result for anyone whose scope holds it —
# in a multi-tenant install, every member of the owning account — and answer
# 404 to anyone else, the same as for a link to nothing.
class EvaluationDeepLinksTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::EvaluationScenarioResult.delete_all
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
  end

  def teardown
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.current_user_resolver = nil
  end

  test "a single-tenant install opens every link shape" do
    links = suite_links(ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini"))

    links.values_at(:evaluation, :run, :result).each do |path|
      get path, headers: { "Accept" => "text/html" }

      assert_response :success, path
      assert_includes response.body, "active-agent-dashboard"
    end
  end

  test "a link whose run or result belongs elsewhere answers 404" do
    agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    first = suite_links(agent, name: "First")
    second = suite_links(agent, name: "Second")

    [
      "/activeagents/evaluations/#{first[:evaluation_id]}/runs/#{second[:run_id]}",
      "/activeagents/evaluations/#{first[:evaluation_id]}/runs/#{first[:run_id]}/results/#{second[:result_id]}",
      "/activeagents/evaluations/#{ActionAgent::Evaluation.maximum(:id) + 1}"
    ].each do |path|
      get path, headers: { "Accept" => "text/html" }

      assert_response :not_found, path
      # The dashboard still renders, so the page can say what happened.
      assert_includes response.body, "active-agent-dashboard"
    end
  end

  test "the run report page keeps its own client-side route" do
    links = suite_links(ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini"))

    get "#{links[:run]}/report", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_includes response.body, "active-agent-dashboard"
  end

  test "every member of the owning account opens the links and the API behind them" do
    use_tenants!
    links = suite_links(account_agent(@account))

    [ @ada, @grace ].each do |member|
      @signed_in = member
      links.values_at(:evaluation, :run, :result).each do |path|
        get path, headers: { "Accept" => "text/html" }
        assert_response :success, "#{member.name}: #{path}"
      end

      get "/activeagents/api/evaluations/#{links[:evaluation_id]}"
      assert_response :success
      get "/activeagents/api/evaluations/#{links[:evaluation_id]}/runs/#{links[:run_id]}"
      assert_response :success
      result_ids = response.parsed_body.dig("run", "results").map { |result| result["id"] }
      assert_includes result_ids, links[:result_id]
    end
  end

  test "another account gets 404 for the links and the API, never 403" do
    use_tenants!
    links = suite_links(account_agent(@account))
    other_account = user("Other Org")
    outsider = user("Outsider")
    @current_account = other_account
    @signed_in = outsider

    links.values_at(:evaluation, :run, :result).each do |path|
      get path, headers: { "Accept" => "text/html" }
      assert_response :not_found, path
    end

    [
      "/activeagents/api/evaluations/#{links[:evaluation_id]}",
      "/activeagents/api/evaluations/#{links[:evaluation_id]}/runs/#{links[:run_id]}",
      "/activeagents/api/evaluations/#{links[:evaluation_id]}/runs/#{links[:run_id]}/report"
    ].each do |path|
      get path
      assert_response :not_found, path
    end
  end

  test "a signed-in user with no account opens nothing" do
    use_tenants!
    links = suite_links(account_agent(@account))
    @current_account = nil

    get links[:evaluation], headers: { "Accept" => "text/html" }

    assert_response :not_found
  end

  private

  # A multi-tenant install like OrganizationProviderKeys's: the dummy app
  # has no Account model, so the account is a User with two members.
  def use_tenants!
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true
    @account = user("Acme")
    @current_account = @account
    @ada = user("Ada")
    @grace = user("Grace")
    @signed_in = @ada
    ActionAgent.current_account_resolver = ->(_controller) { @current_account }
    ActionAgent.current_user_resolver = ->(_controller) { @signed_in }
  end

  def user(name)
    User.create!(name: name, email: "#{name.downcase.tr(' ', '-')}-#{SecureRandom.hex(3)}@example.com", age: 30)
  end

  def account_agent(account)
    ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini", user_id: account.id)
  end

  # A scenario suite with one completed run and one result, and the
  # dashboard paths that link to each.
  def suite_links(agent, name: "Suite")
    evaluation = agent.evaluations.create!(
      name: name, judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ],
      config: { "scenario_suite" => true }
    )
    scenario = evaluation.scenarios.create!(key: "s1", prompt: "Where is order 1234?", position: 0)
    run = evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    result = run.scenario_results.create!(
      scenario: scenario, model: "mock-model", provider: "mock", status: :passed, score: 1.0,
      scores: { "response_present" => 1.0 }, output: "Shipped.", duration_ms: 10
    )
    base = "/activeagents/evaluations/#{evaluation.id}"
    {
      evaluation_id: evaluation.id, run_id: run.id, result_id: result.id,
      evaluation: base, run: "#{base}/runs/#{run.id}", result: "#{base}/runs/#{run.id}/results/#{result.id}"
    }
  end
end
