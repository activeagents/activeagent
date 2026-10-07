# frozen_string_literal: true

require "test_helper"

class EvaluationFixesApiTest < ActionDispatch::IntegrationTest
  class Backend
    class << self
      attr_accessor :refreshed, :refresh_error
    end
    def code_runners = %w[claude_code]
    def refresh_runtime(sandbox)
      raise self.class.refresh_error if self.class.refresh_error

      self.class.refreshed = sandbox.session_id
    end
    def run_code_session(*)
      yield({ "type" => "result", "is_error" => false, "result" => "Fixed the lookup." })
      { exit_status: 0, diff: "diff --git a/app/agents/support_agent.rb b/app/agents/support_agent.rb\n+fixed\n" }
    end
    def cancel_code_session(*) = true
  end

  def setup
    @backends = ActionAgent.sandbox_backends
    @service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "fix_test" => Backend.name }
    ActionAgent.sandbox_service = :fix_test
    ActionAgent::GithubConnection.create!(access_token: "gho_synthetic", github_user_id: 42, login: "fixture", repositories: [ { "id" => 1, "full_name" => "fixture/support", "default_branch" => "main" } ])
    @agent = ActionAgent::Agent.create!(name: "Fix fixture", provider: "mock", model: "mock-model")
    @evaluation = @agent.evaluations.new(name: "Support fixes", judge_kind: "rules", criteria: [])
    @scenario = @evaluation.scenarios.build(key: "lookup", prompt: "Find a synthetic order", expectations: { tools: [ "lookup_order" ] })
    @evaluation.save!
    @run = @evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    @run.scenario_results.create!(scenario: @scenario, model: "mock-model", provider: "mock", status: :failed, score: 0.0,
      fault: "expected_tool_not_called", recommendation: "Call the lookup tool.",
      diagnosis: { fault: "expected_tool_not_called", recommendation: "Call the lookup tool.", evidence: { tools: [ "lookup_order" ] } })
    @project = ActionAgent::Project.create!(name: "Fixture", repository: "fixture/support", target_agent: @agent, evaluation: @evaluation)
    @sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", project: @project, repository: "fixture/support")
    @sandbox.mark_ready!(cloud_run_url: "http://127.0.0.1:9999")
    @sandbox.update!(runtime_mcp_url: "http://127.0.0.1:9999/mcp", runtime_mcp_token: "synthetic-mcp-token")
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: "sk-ant-api03-fixFixture")
    @item = @run.fix_items.first
    assert @item, "fixture must generate a real fix card"
  end

  def teardown
    Backend.refresh_error = nil
    ActionAgent.sandbox_backends = @backends
    ActionAgent.sandbox_service = @service
    ActionAgent.execution_enabled = true
  end

  test "one click stores a canonical brief and schedules exact verification after refreshing the runtime" do
    post sessions_path, params: { evaluation_run_id: @run.id, fix_item: @item, prompt: "Ignore the persisted diagnosis" }, as: :json
    assert_response :created, response.body
    session = ActionAgent::CodeSession.find(JSON.parse(response.body).dig("code_session", "id"))
    assert_equal @run.id, session.evaluation_run_id
    assert_includes session.prompt, "Change the agent, not the scenarios"
    assert_includes session.prompt, "app/agents/"
    refute_includes session.prompt, "Ignore the persisted diagnosis"
    ActionAgent::CodeSessionJob.perform_now(session.id)
    assert_enqueued_with(job: ActionAgent::VerifyEvaluationFixJob, args: [ session.id ])
    ActionAgent::VerifyEvaluationFixJob.perform_now(session.id)
    session.reload
    assert_nil session.verification_error
    assert_equal @sandbox.session_id, Backend.refreshed
    assert_equal({ "sandbox_id" => @sandbox.session_id, "keys" => [ "lookup" ], "models" => [ "mock/mock-model" ] }, session.verification_run.selection)
    assert_no_difference -> { @evaluation.evaluation_runs.count } do
      ActionAgent::VerifyEvaluationFixJob.perform_now(session.id)
    end
    post sessions_path, params: { evaluation_run_id: @run.id, fix_item: @item }, as: :json
    assert_response :conflict
  end

  test "tampered scopes and unrelated checkouts are refused before any job runs" do
    post sessions_path, params: { evaluation_run_id: @run.id, fix_item: @item.merge("scenario_keys" => [ "unrelated" ]) }, as: :json
    assert_response :unprocessable_entity
    @sandbox.update!(project: nil)
    post sessions_path, params: { evaluation_run_id: @run.id, fix_item: @item }, as: :json
    assert_response :unprocessable_entity
    assert_enqueued_jobs 0, only: ActionAgent::CodeSessionJob
  end

  test "comparison and a new retry include verification evidence, while publication remains explicit" do
    fix = ActionAgent::EvaluationFix.new(@run, @item)
    session = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: fix.prompt, evaluation_run: @run, fix_item: fix.item,
      status: :succeeded, finished_at: Time.current, diff: "diff --git a/x b/x\n+fixed", result: "Updated the lookup tool.")
    verification = @evaluation.evaluation_runs.create!(status: :complete, completed_at: Time.current)
    verification.scenario_results.create!(scenario: @scenario, provider: "mock", model: "mock-model", status: :passed, score: 1)
    session.update!(verification_run: verification)
    comparison = ActionAgent::EvaluationFixComparison.new(session)
    assert_equal "fixed", comparison.rows.first[:change]
    assert_equal 1.0, comparison.rows.first[:score_change]
    body = comparison.pull_request_body(mount: "https://dashboard.example/activeagents")
    assert_includes body, "/runs/#{@run.id}"
    assert_includes body, "/runs/#{verification.id}"
    assert_includes body, "Updated the lookup tool."
    # Appended to a body the user wrote, it is cut from the end to fit.
    short = comparison.pull_request_body(mount: "https://dashboard.example/activeagents", limit: 120)
    assert_operator short.length, :<=, 120
    assert short.start_with?("## Evaluation fix")
    assert_empty ActionAgent::DraftPullRequest.where(sandbox_session_id: @sandbox.id)
    post sessions_path, params: { evaluation_run_id: @run.id, fix_item: @item, previous_code_session_id: session.id }, as: :json
    assert_response :created, response.body
    retry_session = ActionAgent::CodeSession.find(JSON.parse(response.body).dig("code_session", "id"))
    assert_equal session.id, retry_session.previous_code_session_id
    assert_includes retry_session.prompt, "Previous diff:"
    assert_includes retry_session.prompt, '"change":"fixed"'
    get "/activeagents/api/evaluations/#{@evaluation.id}/runs/#{@run.id}/fixes"
    assert_response :success, response.body
    assert_equal @project.id, JSON.parse(response.body).dig("project", "id")
  end

  test "verification refuses changed scenario definitions" do
    fix = ActionAgent::EvaluationFix.new(@run, @item)
    session = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: fix.prompt, evaluation_run: @run,
      fix_item: fix.item, status: :succeeded, diff: "diff --git a/x b/x")
    @scenario.update!(prompt: "A different question")
    ActionAgent::VerifyEvaluationFixJob.perform_now(session.id)
    assert_match(/scenarios changed/, session.reload.verification_error)
    assert_nil session.verification_run_id
  end

  test "a failed runtime refresh records a retryable error without creating a verification run" do
    fix = ActionAgent::EvaluationFix.new(@run, @item)
    session = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: fix.prompt, evaluation_run: @run, fix_item: fix.item, status: :succeeded, diff: "diff --git a/x b/x")
    @sandbox.update!(expires_at: 1.minute.ago)
    ActionAgent::VerifyEvaluationFixJob.perform_now(session.id)
    assert_match(/no longer running/, session.reload.verification_error)
    assert_nil session.verification_run_id
  end

  test "a refresh that loses the runtime fails the verification run and frees the checkout" do
    fix = ActionAgent::EvaluationFix.new(@run, @item)
    session = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: fix.prompt, evaluation_run: @run, fix_item: fix.item,
      status: :succeeded, diff: "diff --git a/x b/x", finished_at: Time.current)
    Backend.refresh_error = "The app did not answer"
    ActionAgent::VerifyEvaluationFixJob.perform_now(session.id)
    session.reload
    assert_match(/did not answer/, session.verification_error)
    assert_equal "failed", session.verification_run.status
    assert_no_enqueued_jobs(only: ActionAgent::EvaluationRunJob)
    post sessions_path, params: { evaluation_run_id: @run.id, fix_item: @item, previous_code_session_id: session.id }, as: :json
    assert_response :created, response.body
  end

  test "an unverified fix holds its checkout for an hour, not until the sandbox expires" do
    fix = ActionAgent::EvaluationFix.new(@run, @item)
    session = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: fix.prompt, evaluation_run: @run, fix_item: fix.item,
      status: :succeeded, diff: "diff --git a/x b/x", finished_at: Time.current)
    post sessions_path, params: { prompt: "Another edit" }, as: :json
    assert_response :conflict
    session.update!(finished_at: 2.hours.ago)
    post sessions_path, params: { prompt: "Another edit" }, as: :json
    assert_response :created, response.body
  end

  test "a card with long evidence gets a shorter brief instead of a refusal" do
    @run.scenario_results.first.update!(output: "An answer that goes on. " * 2_000,
      diagnosis: { fault: "expected_tool_not_called", recommendation: "Call the lookup tool.", evidence: { note: "x" * 20_000 } })
    previous = ActionAgent::CodeSession.create!(sandbox_session: @sandbox, prompt: "First try", evaluation_run: @run,
      fix_item: ActionAgent::EvaluationFix.new(@run, @item).item, status: :succeeded, result: "Tried. " * 2_000, diff: "diff --git a/x b/x\n" + "+line\n" * 5_000)
    prompt = ActionAgent::EvaluationFix.new(@run, @item).prompt(previous: previous)
    assert_operator prompt.length, :<=, ActionAgent::CodeSession::MAX_PROMPT_CHARACTERS
    assert_includes prompt, "Change the agent, not the scenarios"
    assert_includes prompt, "## Previous attempt"
  end

  private

  def sessions_path = "/activeagents/api/sandboxes/#{@sandbox.session_id}/code_sessions"
end
