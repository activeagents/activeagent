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

# Where each evaluation stands, which run is its headline, archiving, and
# the costs a run's results carry.
class EvaluationsStandingApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::ModelPricing.reset!
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini", instructions: "Help.")
  end

  def suite(name = "Orders", agent: @agent)
    evaluation = agent.evaluations.create!(name: name, judge_kind: "rules",
                                           criteria: [ { "key" => "present", "type" => "response_present", "config" => {} } ])
    evaluation.scenarios.create!(key: "s1", prompt: "Where is order 1234?", position: 0)
    evaluation
  end

  def complete_run(evaluation, passed: 1, total: 1, created_at: Time.current, **attributes)
    run = evaluation.evaluation_runs.create!({ status: :complete, completed_at: created_at, created_at: created_at,
                                               samples_evaluated: total, samples_passed: passed,
                                               scores: { "_models" => { "gpt-4o-mini" => { "scenarios" => total, "passed" => passed, "cost" => nil } } },
                                               selection: { "models" => [ { "label" => "gpt-4o-mini", "provider" => "openai", "model" => "gpt-4o-mini" } ] } }.merge(attributes))
    run.scenario_results.create!(scenario: evaluation.scenarios.first, model: "gpt-4o-mini", provider: "openai", status: passed.positive? ? :passed : :failed,
                                 score: 1.0, input_tokens: 1_000, output_tokens: 100, cost: nil, output: "Shipped.")
    run
  end

  def body = JSON.parse(response.body)

  test "the index says where each evaluation stands and which run is its headline, with a newer pending run beside it" do
    evaluation = suite
    finished = complete_run(evaluation, created_at: 2.minutes.ago)
    pending = evaluation.evaluation_runs.create!(status: :pending, created_at: 1.minute.ago)
    stale = suite("Old suite")
    complete_run(stale, created_at: 3.minutes.ago)
    @agent.update!(instructions: "Help, politely.")
    current = complete_run(evaluation, created_at: 30.seconds.ago)
    pending.update!(created_at: Time.current)

    get "/activeagents/api/evaluations"

    assert_response :success
    listed = body["evaluations"].index_by { |entry| entry["name"] }
    orders = listed["Orders"]
    assert_equal "current", orders["standing"]
    assert_equal current.id, orders["headline_run_id"]
    assert_equal pending.id, orders.dig("latest_run", "id"), "the newest run, pending, is still the latest"
    assert_equal current.id, orders.dig("headline_run", "id"), "the headline run rides along in full when it is not the latest"
    assert_equal({ "gpt-4o-mini" => { "passed" => 1, "total" => 1 } }, orders["per_model"])
    assert_nil orders["archived_at"]
    assert_equal "current", orders.dig("headline_run", "version_state")
    assert_equal @agent.latest_version.id, orders.dig("headline_run", "agent_version", "id")
    assert_equal false, orders.dig("headline_run", "agent_version", "release")
    assert_equal "earlier", body["evaluations"].flat_map { |e| [ e["latest_run"], e["headline_run"] ] }.compact.find { |run| run["id"] == finished.id }&.dig("version_state") || "earlier"
    assert_equal "stale", listed["Old suite"]["standing"]
    assert_equal "earlier", listed["Old suite"].dig("latest_run", "version_state")
    assert_nil listed["Old suite"]["headline_run"], "the headline is the latest run, so it is not repeated"
    assert_equal 0, body["archived_count"]
  end

  test "an evaluation can be archived and brought back, and the index leaves archived ones out unless asked" do
    kept = suite("Kept")
    complete_run(kept)
    retired = suite("Retired")
    complete_run(retired)

    patch "/activeagents/api/evaluations/#{retired.id}", params: { evaluation: { archived: true } }, as: :json
    assert_response :success
    assert_equal "archived", body.dig("evaluation", "standing")
    assert body.dig("evaluation", "archived_at").present?

    get "/activeagents/api/evaluations"
    assert_equal [ "Kept" ], body["evaluations"].map { |entry| entry["name"] }
    assert_equal 1, body["archived_count"]

    get "/activeagents/api/evaluations", params: { archived: 1 }
    assert_equal %w[Kept Retired], body["evaluations"].map { |entry| entry["name"] }.sort
    assert_equal 1, body["archived_count"]

    get "/activeagents/api/evaluations", params: { agent_id: @agent.id }
    assert_equal [ "Kept" ], body["evaluations"].map { |entry| entry["name"] }

    patch "/activeagents/api/evaluations/#{retired.id}", params: { evaluation: { archived: false } }, as: :json
    assert_response :success
    assert_equal "current", body.dig("evaluation", "standing")
    assert_nil body.dig("evaluation", "archived_at")

    patch "/activeagents/api/evaluations/#{retired.id}", params: { evaluation: { name: "x" } }, as: :json
    assert_response :unprocessable_entity
  end

  test "a new run brings an archived evaluation back" do
    evaluation = suite
    evaluation.archive!
    assert evaluation.archived?

    complete_run(evaluation)
    assert_not evaluation.reload.archived?
  end

  test "a run's results carry their effective cost and how it was priced, and the run its costs per scenario" do
    evaluation = suite
    run = complete_run(evaluation)
    run.scenario_results.create!(scenario: evaluation.scenarios.first, model: "gpt-4o", provider: "openai", status: :errored, score: nil,
                                 input_tokens: 0, output_tokens: 0, error_message: "boom")

    get "/activeagents/api/evaluations/#{evaluation.id}/runs/#{run.id}"

    assert_response :success
    results = body.dig("run", "results").index_by { |result| result["model"] }
    priced = results["gpt-4o-mini"]
    assert_equal "estimated", priced["cost_source"]
    assert_nil priced["reported_cost"]
    assert_operator priced["cost"], :>, 0
    assert_equal %w[basis input input_tokens output output_tokens source], priced["cost_rate"].keys.sort
    assert_equal 1_000, priced.dig("cost_rate", "input_tokens")
    assert_nil priced["judge_usage"]
    errored = results["gpt-4o"]
    assert_equal [ 0.0, "no_usage", nil ], errored.values_at("cost", "cost_source", "cost_rate"), "no usage is $0.00, never a blank"

    costs = body.dig("run", "costs")
    scenario = costs.dig("scenarios", "s1")
    assert_in_delta priced["cost"], scenario["cost"], 1e-9
    assert_nil scenario["judge_cost"]
    assert_in_delta priced["cost"], scenario["total"], 1e-9
    assert scenario["estimated"]
    assert_equal({ "cost" => priced["cost"], "judge_cost" => nil, "cost_source" => "estimated" }, scenario.dig("models", "gpt-4o-mini"))
    assert_equal({ "cost" => 0.0, "judge_cost" => nil, "cost_source" => "no_usage" }, scenario.dig("models", "gpt-4o"))
    assert_equal [ priced["cost"], nil, priced["cost"], "estimated" ], costs["run"].values_at("agent_cost", "judge_cost", "total", "cost_basis")

    usage = body.dig("run", "usage")
    assert_equal [ 2, 2, 0, 0, 1, "estimated" ], usage.values_at("replays", "priced", "unpriced", "reported", "estimated", "cost_basis")
    assert_in_delta priced["cost"], usage["total"], 1e-9
    models = body.dig("run", "scores", "_models", "gpt-4o-mini")
    assert_equal [ 1, 0, 1 ], models.values_at("priced", "reported", "estimated")
    assert_in_delta priced["cost"], models["cost"], 1e-9
  end
end
