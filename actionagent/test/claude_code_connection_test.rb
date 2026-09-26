# frozen_string_literal: true

require "test_helper"
require "rake"

# Settings -> Integrations: connecting Claude Code with an Anthropic API key,
# stored like a provider key and handed to checkout sandboxes (#478). Claude
# subscription tokens (`claude setup-token`, sk-ant-oat…) are refused, and one
# an earlier version stored is never handed out: Anthropic does not let
# third-party products store Claude.ai credentials
# (https://code.claude.com/docs/en/legal-and-compliance.md).
class ClaudeCodeConnectionTest < ActionDispatch::IntegrationTest
  SUBSCRIPTION_TOKEN = "sk-ant-oat01-abcDEF_123-xyz"
  API_KEY = "sk-ant-api03-abcDEF_123-xyz"

  def setup
    ActionAgent::ProviderKey.delete_all
    ActionAgent::GithubConnection.delete_all
    ActionAgent::SandboxSession.delete_all
  end

  test "a Claude Code API key is stored write-only and listed as a connection" do
    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: API_KEY }

    assert_response :created
    assert_not_includes response.body, API_KEY

    get "/activeagents/api/provider_keys"
    row = JSON.parse(response.body)["provider_keys"].find { |r| r["provider"] == "claude_code" }
    assert row["configured"]
    assert_equal "connection", row["kind"]
    assert_equal "sk-a…-xyz", row["hint"]
    assert_equal false, row["needs_replacing"]
  end

  test "anything but an Anthropic API key is refused" do
    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: "sk-or-v1-not-anthropic" }

    assert_response :unprocessable_entity
    assert_match(/Anthropic API key/, JSON.parse(response.body)["error"].join)
    assert_equal 0, ActionAgent::ProviderKey.count
  end

  test "a Claude subscription token is refused, and the refusal says why and what to use instead" do
    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: SUBSCRIPTION_TOKEN }

    assert_response :unprocessable_entity
    assert_not_includes response.body, SUBSCRIPTION_TOKEN
    error = JSON.parse(response.body)["error"].join
    assert_match(/subscription tokens/, error)
    assert_match(%r{https://platform\.claude\.com}, error)
    assert_match(/claude_code_auth = :local_login/, error)
    assert_equal 0, ActionAgent::ProviderKey.count

    # Nor does one replace a stored API key.
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: API_KEY)
    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: SUBSCRIPTION_TOKEN }
    assert_response :unprocessable_entity
    assert_equal API_KEY, ActionAgent::ProviderKey.find_by!(provider: "claude_code").credential
  end

  test "the runtime environment hands Claude Code the API key as ANTHROPIC_API_KEY" do
    api = ActionAgent::ProviderKey.new(provider: "claude_code", credential: API_KEY)

    assert_equal({ "ANTHROPIC_API_KEY" => API_KEY }, api.runtime_environment)
    assert_empty api.generation_options, "a connection configures no generation"
    assert_empty ActionAgent::ProviderKey.new(provider: "openai", credential: "sk-x").runtime_environment
  end

  test "a subscription token stored by an earlier version is never handed out, and is flagged for replacing" do
    stored = store_subscription_token!

    assert stored.needs_replacing?
    assert_equal({}, stored.runtime_environment)
    assert_not ActionAgent::ProviderKey.new(provider: "claude_code", credential: API_KEY).needs_replacing?

    get "/activeagents/api/provider_keys"
    row = JSON.parse(response.body)["provider_keys"].find { |r| r["provider"] == "claude_code" }
    assert row["configured"]
    assert_equal true, row["needs_replacing"]
    assert_not_includes response.body, SUBSCRIPTION_TOKEN

    # The owner's checkout gets nothing, and Claude Code reads as not
    # connected.
    assert_equal({}, ActionAgent::SandboxSession.new(sandbox_type: "app_runtime").runtime_environment)
    get "/activeagents/api/sandboxes"
    assert_equal false, JSON.parse(response.body)["claude_code_connected"]

    # Replacing it with an API key clears the flag.
    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: API_KEY }
    assert_response :created
    assert_equal false, JSON.parse(response.body).dig("provider_key", "needs_replacing")
  end

  test "action_agent:claude_code:purge_subscription_tokens deletes stored subscription tokens and prints the count" do
    # Several owners' (the owner column is not checked here: rows as a
    # multi-user install holds them).
    store_subscription_token!(user_id: 97)
    store_subscription_token!(user_id: 99)
    ActionAgent::ProviderKey.new(provider: "claude_code", credential: API_KEY, user_id: 98).save!(validate: false)
    ActionAgent::ProviderKey.create!(provider: "anthropic", credential: "sk-ant-oat01-not-a-connection")

    output = capture_io { run_task("action_agent:claude_code:purge_subscription_tokens") }.first

    assert_equal "Deleted 2 stored Claude subscription token(s)\n", output
    assert_equal [ API_KEY ], ActionAgent::ProviderKey.where(provider: "claude_code").map(&:credential)
    assert ActionAgent::ProviderKey.exists?(provider: "anthropic"), "only Claude Code connections are purged"

    output = capture_io { run_task("action_agent:claude_code:purge_subscription_tokens") }.first
    assert_equal "Deleted 0 stored Claude subscription token(s)\n", output
  end

  test "Claude Code is never an agent provider" do
    assert_not_includes ActionAgent::Agent::PROVIDERS, "claude_code"

    get "/activeagents/api/provider_models", params: { provider: "claude_code" }
    assert_response :unprocessable_entity
  end

  test "a checkout sandbox hands the backend the owner's Claude Code API key" do
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: API_KEY)
    ActionAgent::GithubConnection.create!(
      access_token: "gho_secret", github_user_id: 42, login: "octocat",
      repositories: [ { "id" => 2, "full_name" => "acme/docs", "private" => false, "default_branch" => "trunk" } ]
    )

    # Provisioning a checkout runs in the background; run it here, so the
    # session is handed to the backend.
    perform_enqueued_jobs do
      post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json
    end

    assert_response :created, response.body
    assert_not_includes response.body, API_KEY
    session = ActionAgent::SandboxSession.find_by!(session_id: JSON.parse(response.body).dig("sandbox", "session_id"))
    assert session.ready?, "the backend booted the checkout"
    assert_equal({ "ANTHROPIC_API_KEY" => API_KEY }, session.runtime_environment)
  end

  test "sandboxes other than checkouts get no credentials" do
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: API_KEY)
    session = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")

    assert_empty session.runtime_environment
  end

  private

  # A subscription token as an earlier version stored it, before they were
  # refused.
  def store_subscription_token!(**owner)
    ActionAgent::ProviderKey.new(provider: "claude_code", credential: SUBSCRIPTION_TOKEN, **owner).tap do |key|
      key.save!(validate: false)
    end
  end

  # Invokes +name+ in a fresh Rake application holding the engine's tasks, as
  # `bin/rails <name>` would. The environment is already loaded here.
  def run_task(name)
    original = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    ActionAgent::Engine.instance.load_tasks
    Rake::Task[name].invoke
  ensure
    Rake.application = original
  end
end
