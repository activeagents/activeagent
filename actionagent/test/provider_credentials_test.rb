# frozen_string_literal: true

require "test_helper"
require_relative "support/organization_provider_keys"

# ActionAgent::ProviderCredentials: the order credentials are tried in, the
# actor handed to a host resolver, failing closed on a multi-tenant install,
# and the generations that resolve through it.
class ProviderCredentialsTest < ActionDispatch::IntegrationTest
  include OrganizationProviderKeys

  test "under :organization a personal key is never used, and the order is host resolver, organization, config" do
    assert_resolution "organization", "sk-ant-organization", actor: @ada

    ActionAgent.provider_credentials_resolver = ->(_owner, _provider) { { access_token: "sk-ant-host" } }
    assert_resolution "host_resolver", "sk-ant-host", actor: @ada

    ActionAgent.provider_credentials_resolver = ->(_owner, _provider) { {} }
    assert_resolution "organization", "sk-ant-organization", actor: @ada

    @organization_key.destroy!
    assert_equal "none", resolve(actor: @ada).source
    with_provider_config(anthropic: { access_token: "sk-ant-config" }) do
      assert_equal [ "config", {} ], [ resolve(actor: @ada).source, resolve(actor: @ada).options ]
    end
  end

  test "under :personal_override the actor's own key comes first" do
    ActionAgent.provider_key_scope = :personal_override
    ActionAgent.provider_credentials_resolver = ->(_owner, _provider) { { access_token: "sk-ant-host" } }

    assert_resolution "personal", "sk-ant-ada", actor: @ada
    assert_resolution "personal", "sk-ant-grace", actor: @grace
    assert_resolution "host_resolver", "sk-ant-host", actor: nil

    ActionAgent.provider_credentials_resolver = nil
    assert_resolution "organization", "sk-ant-organization", actor: nil
    assert_resolution "organization", "sk-ant-organization", actor: user("Linus"), message: "a member with no personal key"
  end

  test "a two-argument resolver is called with the owner and provider, one that declares actor: is also told the actor" do
    calls = []
    ActionAgent.provider_credentials_resolver = ->(owner, provider) { calls << [ owner, provider ]; {} }
    resolve(actor: @ada)
    assert_equal [ [ @account, "anthropic" ] ], calls

    calls.clear
    ActionAgent.provider_credentials_resolver = ->(owner, provider, actor: nil) { calls << [ owner, provider, actor ]; {} }
    resolve(actor: @ada)
    assert_equal [ [ @account, "anthropic", @ada ] ], calls

    calls.clear
    ActionAgent.provider_credentials_resolver = ->(owner, provider, **options) { calls << [ owner, provider, options ]; {} }
    resolve(actor: @grace)
    assert_equal [ [ @account, "anthropic", { actor: @grace } ] ], calls

    calls.clear
    ActionAgent.provider_credentials_resolver = ->(*arguments) { calls << arguments; {} }
    resolve(actor: @grace)
    assert_equal [ [ @account, "anthropic" ] ], calls
  end

  test "multi-tenant: a raising resolver and an owner of another class are unresolved" do
    ActionAgent.provider_credentials_resolver = ->(*) { raise "billing service down" }
    assert_raises(ActionAgent::ProviderCredentials::Unresolved) { resolve(actor: @ada) }

    ActionAgent.provider_credentials_resolver = nil
    assert_raises(ActionAgent::ProviderCredentials::Unresolved) { resolve(owner: Object.new, actor: @ada) }
    assert_raises(ActionAgent::ProviderCredentials::Unresolved) { resolve(owner: nil, actor: @ada) }
  end

  test "single-tenant: a raising resolver is logged and the stored key applies, as before" do
    ActionAgent.multi_tenant = false
    ActionAgent.provider_credentials_resolver = ->(*) { raise "billing service down" }

    assert_resolution "organization", "sk-ant-organization", actor: @ada
  end

  test "under :personal_override a run generates with its actor's personal key, others with the organization's" do
    ActionAgent.provider_key_scope = :personal_override
    agent = anthropic_agent
    keys = []
    stub_request(:post, ANTHROPIC_URL).to_return do |request|
      keys << request.headers["X-Api-Key"]
      anthropic_reply
    end

    [ @ada, @grace, user("Linus"), nil ].each { |actor| agent.test_execute("Hello", actor: actor) }

    assert_equal %w[sk-ant-ada sk-ant-grace sk-ant-organization sk-ant-organization], keys
    assert agent.agent_runs.all?(&:complete?), agent.agent_runs.map(&:error_message).inspect
  end

  test "the evaluation judge uses the organization key even under :personal_override" do
    ActionAgent.provider_key_scope = :personal_override
    evaluation = anthropic_agent.evaluations.create!(
      name: "Judged", judge_kind: "llm", criteria: [ { "key" => "quality", "type" => "llm_judge" } ]
    )

    options = ActionAgent::EvaluationRunnerService.new(evaluation).send(:owner_provider_options, :anthropic)

    assert_equal "sk-ant-organization", options[:access_token]
  end

  test "the secrets to mask hold every organization key, then the most recently saved personal keys" do
    @grace_key.touch(time: 1.minute.from_now)
    key("openai", "sk-organization-openai")

    secrets = ActionAgent::ProviderCredentials.secrets_for(@account, limit: 1)

    assert_equal %w[sk-ant-grace sk-ant-organization sk-organization-openai], secrets.sort
  end

  test "the evaluation form offers only the providers a scenario replay can use" do
    ActionAgent.provider_key_scope = :personal_override
    key("openai", "sk-ada-openai", member: @ada)

    with_provider_config({}) { get "/activeagents/api/evaluations" }

    assert_response :success
    assert_equal %w[anthropic], response.parsed_body["model_providers"], "Ada's personal OpenAI key reaches no replay"
  end

  test "multi-tenant: a run whose credentials are unresolved fails without building a provider client" do
    ActionAgent.provider_credentials_resolver = ->(*) { raise "billing service down" }
    agent = anthropic_agent
    stub_request(:post, ANTHROPIC_URL).to_return(anthropic_reply)

    run = agent.test_execute("Hello", actor: @ada)

    assert run.failed?
    assert_equal "ActionAgent::ProviderCredentials::Unresolved", run.output_metadata["error_class"]
    assert_not_requested :post, ANTHROPIC_URL

    ActionAgent.provider_credentials_resolver = nil
    stranger = ActionAgent::Agent.create!(name: "Stray", provider: "anthropic", model: "claude-haiku-4-5", instructions: "Hi.")
    run = stranger.test_execute("Hello", actor: @ada)
    assert_equal "ActionAgent::ProviderCredentials::Unresolved", run.output_metadata["error_class"], "an agent with no owner"
    assert_not_requested :post, ANTHROPIC_URL
  end

  test "with OPENROUTER_API_KEY in ENV, a stored OpenRouter key is the one a run sends" do
    require "active_agent/providers/open_router_provider"
    precedence_fixed = with_env("OPENROUTER_API_KEY" => "sk-or-env") do
      ActiveAgent::Providers::OpenRouter::Options.new(access_token: "sk-or-stored").api_key == "sk-or-stored"
    end
    skip "needs the OpenRouter fix that lets an explicit key beat OPENROUTER_API_KEY" unless precedence_fixed

    ActionAgent.provider_key_scope = :personal_override
    key("openrouter", "sk-or-organization")
    key("openrouter", "sk-or-ada", member: @ada)
    agent = ActionAgent::Agent.create!(name: "Router", provider: "openrouter", model: "fixture/model", instructions: "Hi.", user_id: @account.id)
    sent = []
    stub_request(:post, OPENROUTER_URL).to_return do |request|
      sent << request.headers["Authorization"]
      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "router_fixture", object: "chat.completion", created: 1, model: "fixture/model",
        choices: [ { index: 0, message: { role: "assistant", content: "Hello." }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 }
      }.to_json }
    end

    with_env("OPENROUTER_API_KEY" => "sk-or-env") do
      agent.test_execute("Hello", actor: @ada)
      agent.test_execute("Hello", actor: nil)
    end

    assert_equal [ "Bearer sk-or-ada", "Bearer sk-or-organization" ], sent
  end

  test "the dashboard assistant generates with the signed-in user's effective key" do
    ActionAgent.provider_key_scope = :personal_override
    keys = []
    stub_request(:post, ANTHROPIC_URL).to_return do |request|
      keys << request.headers["X-Api-Key"]
      anthropic_reply("Pick an evaluation.")
    end

    post "/activeagents/api/dashboard_assistant", as: :json, params: {
      message: "Which evaluation failed?", history: [], provider: "anthropic", model: "claude-haiku-4-5",
      allow_provider_processing: true
    }

    assert_response :success, response.body
    assert_equal [ "sk-ant-ada" ], keys
  end

  test "the model pickers use the signed-in user's effective Anthropic key and Ollama host" do
    ActionAgent.provider_key_scope = :personal_override
    key("ollama", "http://ollama.organization:11434")
    key("ollama", "http://ollama.ada:11434", member: @ada, api_key: "sk-ollama-ada")
    stub_request(:get, "https://api.anthropic.com/v1/models?limit=50")
      .with(headers: { "x-api-key" => "sk-ant-ada" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { data: [ { id: "claude-ada" } ] }.to_json)
    stub_request(:get, "http://ollama.ada:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-ollama-ada" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { data: [ { id: "qwen-ada" } ] }.to_json)

    get "/activeagents/api/provider_models", params: { provider: "anthropic" }
    assert_equal "live", response.parsed_body["source"]
    assert_equal "claude-ada", response.parsed_body["models"].first

    get "/activeagents/api/provider_models", params: { provider: "ollama" }
    assert_equal "live", response.parsed_body["source"]
    assert_equal "qwen-ada", response.parsed_body["models"].first
  end
end
