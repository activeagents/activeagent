# frozen_string_literal: true

require "test_helper"

class CodexConnectionTest < ActionDispatch::IntegrationTest
  KEY = "sk-proj-syntheticCodexKey_0123456789"

  def setup
    ActionAgent::ProviderKey.delete_all
  end

  test "Codex keys are write-only connection credentials rather than agent provider keys" do
    post "/activeagents/api/provider_keys", params: { provider: "codex", credential: KEY }
    assert_response :created
    assert_not_includes response.body, KEY
    assert_equal "connection", JSON.parse(response.body).dig("provider_key", "kind")
    assert_equal({ "CODEX_API_KEY" => KEY }, ActionAgent::ProviderKey.sole.runtime_environment)
    assert_not_includes ActionAgent::Agent::PROVIDERS, "codex"

    %w[not-an-api-key sk-ant-oat01-wrongProvider sk-ant-api03-wrongProvider sk-or-v1-wrongProvider].each do |credential|
      post "/activeagents/api/provider_keys", params: { provider: "codex", credential: credential }
      assert_response :unprocessable_entity
    end
    assert_equal KEY, ActionAgent::ProviderKey.sole.credential
  end

  test "Codex credentials are scoped to the sandbox owner and selected runner" do
    original = %i[user_class account_class multi_tenant].index_with { |name| ActionAgent.public_send(name) }
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "Account"
    ActionAgent.multi_tenant = true
    ActionAgent::ProviderKey.create!(provider: "codex", user_id: 101, account_id: 201, credential: KEY)
    ActionAgent::ProviderKey.create!(provider: "claude_code", user_id: 101, account_id: 201, credential: "sk-ant-api03-fixtureOnly")
    sandbox = ActionAgent::SandboxSession.new(sandbox_type: "app_runtime", user_id: 101, account_id: 201)
    assert_equal({ "CODEX_API_KEY" => KEY }, sandbox.runtime_environment(runner: "codex"))
    assert_equal [ "ANTHROPIC_API_KEY" ], sandbox.runtime_environment.keys
    sandbox.account_id = 202
    assert_empty sandbox.runtime_environment(runner: "codex")
    sandbox.account_id = 201
    ActionAgent.account_class = nil
    ActionAgent.multi_tenant = false
    sandbox.user_id = 102
    assert_empty sandbox.runtime_environment(runner: "codex")
    sandbox.user_id = 101
    sandbox.sandbox_type = "playwright_mcp"
    assert_empty sandbox.runtime_environment(runner: "codex")
  ensure
    original.each { |name, value| ActionAgent.public_send("#{name}=", value) } if original
  end
end
