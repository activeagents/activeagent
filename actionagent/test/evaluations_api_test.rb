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

  # The runs list numbers runs from the oldest, and the index carries the
  # run before the latest so a row can say "+3 passed vs #2" without a
  # request per evaluation.
  test "runs are numbered oldest-first and the list carries the run before the latest" do
    record_generations(@agent, 2)

    post "/activeagents/api/evaluations", params: { evaluation: { agent_id: @agent.id, name: "Numbered" } }, as: :json
    assert_response :created
    body = JSON.parse(response.body)
    evaluation_id = body.dig("evaluation", "id")
    assert_equal 1, body.dig("evaluation", "run_count")
    assert_equal 1, body.dig("evaluation", "latest_run", "number")
    assert_nil body.dig("evaluation", "previous_run")

    post "/activeagents/api/evaluations/#{evaluation_id}/run"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body.dig("run", "number")
    assert_equal 2, body.dig("evaluation", "run_count")
    assert_equal 2, body.dig("evaluation", "latest_run", "number")
    assert_equal 1, body.dig("evaluation", "previous_run", "number")

    get "/activeagents/api/evaluations"
    assert_response :success
    evaluation = JSON.parse(response.body)["evaluations"].find { |entry| entry["id"] == evaluation_id }
    assert_equal 2, evaluation["run_count"]
    assert_equal 2, evaluation.dig("latest_run", "number")
    assert_equal 1, evaluation.dig("previous_run", "number")
    assert_equal 2, evaluation.dig("previous_run", "samples_evaluated")
    refute evaluation["previous_run"].key?("scores"), "the previous run is a summary, not a full payload"

    get "/activeagents/api/evaluations/#{evaluation_id}"
    assert_response :success
    runs = JSON.parse(response.body).dig("evaluation", "runs")
    assert_equal [ 2, 1 ], runs.map { |run| run["number"] }
    # A sampling run summarizes its cohorts and prices them as the agent's
    # operating cost; it asked no judge, so it records no judge spend.
    cohort = runs.first.dig("scores", "_cohorts", "gpt-4o-mini")
    assert_equal 2, cohort["samples"]
    assert_equal 2, cohort["passed"]
    assert_equal 2, runs.first.dig("usage", "samples")
    assert_in_delta cohort["cost"], runs.first.dig("usage", "cost"), 1e-9
    assert_nil runs.first.dig("usage", "judge")
  end

  # The form's model pickers offer the models of the provider the judge runs
  # on, and of the providers the owner's runs can use.
  test "the index names the judge's provider and the providers runs have credentials for" do
    ActionAgent::ProviderKey.delete_all

    with_provider_config({}) { get "/activeagents/api/evaluations" }

    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?("judge_provider")
    assert_nil body["judge_provider"]
    assert_equal false, body["judge_provider_error"]
    assert_equal [], body["model_providers"]

    ActionAgent::ProviderKey.create!(provider: "anthropic", credential: "sk-ant-owner")
    with_provider_config({ ollama: { host: "http://localhost:11434" } }) { get "/activeagents/api/evaluations" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "anthropic", body["judge_provider"]
    # The host's Ollama serves agent runs, but a judge runs on Ollama only
    # with the owner's own host.
    assert_equal %w[anthropic ollama], body["model_providers"]
  ensure
    ActionAgent::ProviderKey.delete_all
  end

  test "the index looks up credentials for the signed-in owner" do
    ActionAgent::ProviderKey.delete_all
    owner = Struct.new(:id).new(4242)
    original_user = ActionAgent.current_user_resolver
    original_credentials = ActionAgent.provider_credentials_resolver
    ActionAgent.current_user_resolver = ->(_controller) { owner }
    ActionAgent.provider_credentials_resolver = lambda do |candidate, provider|
      candidate.equal?(owner) && provider == "openrouter" ? { access_token: "sk-or-owner" } : {}
    end

    with_provider_config({}) { get "/activeagents/api/evaluations" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "openrouter", body["judge_provider"]
    assert_equal %w[openrouter], body["model_providers"]
  ensure
    ActionAgent.current_user_resolver = original_user
    ActionAgent.provider_credentials_resolver = original_credentials
  end

  # A stored key stops decrypting when the host's encryption keys change.
  test "a key that no longer decrypts leaves the list loading and the judge's provider unknown" do
    ActionAgent::ProviderKey.delete_all
    retired_keys = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("a retired encryption key")
    ActiveRecord::Encryption.with_encryption_context(key_provider: retired_keys) do
      ActionAgent::ProviderKey.create!(provider: "anthropic", credential: "sk-ant-retired")
    end
    ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-openai-owner")

    with_provider_config({}) { get "/activeagents/api/evaluations" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body["judge_provider"]
    assert_equal true, body["judge_provider_error"]
    assert_equal %w[openai], body["model_providers"], "the provider whose key cannot be read is left out"
  ensure
    ActionAgent::ProviderKey.delete_all
  end

  # Agent runs and their judge use the agent's owner's credentials, which are
  # not the signed-in owner's when the host's agent scope reaches agents
  # another owner owns.
  test "a list scoped to one agent reports its owner's providers" do
    ActionAgent::ProviderKey.delete_all
    original = [ ActionAgent.user_class, ActionAgent.current_user_resolver, ActionAgent.agent_scope_resolver,
                 ActionAgent.provider_credentials_resolver ]
    ActionAgent.user_class = "User"
    agent_owner = User.create!(name: "Agent Owner", email: "agent-owner-#{SecureRandom.hex(4)}@example.com", age: 30)
    viewer = User.create!(name: "Viewer", email: "viewer-#{SecureRandom.hex(4)}@example.com", age: 30)
    @agent.update!(user_id: agent_owner.id)
    ActionAgent.current_user_resolver = ->(_controller) { viewer }
    ActionAgent.agent_scope_resolver = ->(_owner) { ActionAgent::Agent.all }
    ActionAgent.provider_credentials_resolver = lambda do |owner, provider|
      owner&.id == agent_owner.id && provider == "openrouter" ? { access_token: "sk-or-agent-owner" } : {}
    end

    with_provider_config({}) { get "/activeagents/api/evaluations", params: { agent_id: @agent.id } }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "openrouter", body["judge_provider"]
    assert_equal %w[openrouter], body["model_providers"]

    with_provider_config({}) { get "/activeagents/api/evaluations" }

    body = JSON.parse(response.body)
    assert_nil body["judge_provider"], "an unscoped list reports the signed-in owner's providers"
    assert_equal [], body["model_providers"]
  ensure
    ActionAgent.user_class, ActionAgent.current_user_resolver, ActionAgent.agent_scope_resolver,
      ActionAgent.provider_credentials_resolver = original
    agent_owner&.destroy
    viewer&.destroy
  end

  # Without scenarios an evaluation compares the generations recorded under
  # each model name, which is the provider's own dated id rather than the
  # name the agent asked for.
  test "an agent's recorded model names are listed most recently used first" do
    context = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "SupportAgent", action_name: "respond")
    [ [ "gpt-4o-mini-2024-07-18", 4.days.ago ], [ "claude-haiku-4-5-20251001", 2.days.ago ],
      [ "gpt-4o-mini-2024-07-18", 1.day.ago ], [ nil, Time.current ], [ "", Time.current ] ].each do |model, at|
      context.generations.create!(content: "An answer.", model: model, created_at: at)
    end
    other = ActionAgent::Agent.create!(name: "Other", provider: "openai", model: "gpt-5")
    ActionAgent::AgentContext.create!(contextable: other, agent_name: "OtherAgent", action_name: "respond")
      .generations.create!(content: "Elsewhere.", model: "gpt-5-2025-08-07")

    get "/activeagents/api/agents/#{@agent.id}/recorded_models"

    assert_response :success
    # Neither alphabetical order nor order of first use.
    assert_equal %w[gpt-4o-mini-2024-07-18 claude-haiku-4-5-20251001], JSON.parse(response.body)["models"]
  end

  test "an agent's recorded model names stop at the limit, dropping the least recently used" do
    limit = ActionAgent::Api::AgentsController::RECORDED_MODELS_LIMIT
    context = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "SupportAgent", action_name: "respond")
    (limit + 1).times do |index|
      context.generations.create!(content: "An answer.", model: "model-#{index}", created_at: (limit + 1 - index).hours.ago)
    end

    get "/activeagents/api/agents/#{@agent.id}/recorded_models"

    assert_response :success
    models = JSON.parse(response.body)["models"]
    assert_equal limit, models.size
    assert_equal "model-#{limit}", models.first
    assert_not_includes models, "model-0"
  end

  private

  # Runs the block with `config` standing in for the host's provider config,
  # so the test environment's own keys play no part.
  def with_provider_config(config, &)
    ActiveAgent.stub(:configuration, config, &)
  end

  def record_generations(agent, count)
    context = ActionAgent::AgentContext.create!(contextable: agent, agent_name: "SupportAgent", action_name: "respond")
    count.times do |index|
      context.generations.create!(
        content: "A sufficiently long answer number #{index} with enough substance to pass the length rule.",
        model: "gpt-4o-mini", provider: "openai", input_tokens: 120, output_tokens: 40, duration_seconds: 0.8,
        finish_reason: "stop"
      )
    end
  end
end
