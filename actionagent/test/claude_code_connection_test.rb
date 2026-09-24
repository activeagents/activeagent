# frozen_string_literal: true

require "test_helper"

# Settings -> Integrations: connecting Claude Code with a `claude setup-token`
# token or an Anthropic API key, stored like a provider key and handed to
# checkout sandboxes (#478).
class ClaudeCodeConnectionTest < ActionDispatch::IntegrationTest
  OAUTH_TOKEN = "sk-ant-oat01-abcDEF_123-xyz"
  API_KEY = "sk-ant-api03-abcDEF_123-xyz"

  def setup
    ActionAgent::ProviderKey.delete_all
    ActionAgent::GithubConnection.delete_all
    ActionAgent::SandboxSession.delete_all
  end

  test "a Claude Code token is stored write-only and listed as a connection" do
    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: OAUTH_TOKEN }

    assert_response :created
    assert_not_includes response.body, OAUTH_TOKEN

    get "/activeagents/api/provider_keys"
    row = JSON.parse(response.body)["provider_keys"].find { |r| r["provider"] == "claude_code" }
    assert row["configured"]
    assert_equal "connection", row["kind"]
    assert_equal "sk-a…-xyz", row["hint"]
  end

  test "anything but a Claude Code token or Anthropic key is refused" do
    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: "sk-or-v1-not-anthropic" }

    assert_response :unprocessable_entity
    assert_match(/claude setup-token/, JSON.parse(response.body)["error"].join)
    assert_equal 0, ActionAgent::ProviderKey.count
  end

  test "the runtime environment names the variable Claude Code reads" do
    oauth = ActionAgent::ProviderKey.new(provider: "claude_code", credential: OAUTH_TOKEN)
    api = ActionAgent::ProviderKey.new(provider: "claude_code", credential: API_KEY)

    assert_equal({ "CLAUDE_CODE_OAUTH_TOKEN" => OAUTH_TOKEN }, oauth.runtime_environment)
    assert_equal({ "ANTHROPIC_API_KEY" => API_KEY }, api.runtime_environment)
    assert_empty oauth.generation_options, "a connection configures no generation"
    assert_empty ActionAgent::ProviderKey.new(provider: "openai", credential: "sk-x").runtime_environment
  end

  test "Claude Code is never an agent provider" do
    assert_not_includes ActionAgent::Agent::PROVIDERS, "claude_code"

    get "/activeagents/api/provider_models", params: { provider: "claude_code" }
    assert_response :unprocessable_entity
  end

  test "a checkout sandbox hands the backend the owner's Claude Code credential" do
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: OAUTH_TOKEN)
    ActionAgent::GithubConnection.create!(
      access_token: "gho_secret", github_user_id: 42, login: "octocat",
      repositories: [ { "id" => 2, "full_name" => "acme/docs", "private" => false, "default_branch" => "trunk" } ]
    )

    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json

    assert_response :created, response.body
    assert_not_includes response.body, OAUTH_TOKEN
    session = ActionAgent::SandboxSession.find_by!(session_id: JSON.parse(response.body).dig("sandbox", "session_id"))
    assert_equal({ "CLAUDE_CODE_OAUTH_TOKEN" => OAUTH_TOKEN }, session.runtime_environment)
  end

  test "sandboxes other than checkouts get no credentials" do
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: OAUTH_TOKEN)
    session = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")

    assert_empty session.runtime_environment
  end
end
