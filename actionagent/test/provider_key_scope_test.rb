# frozen_string_literal: true

require "test_helper"
require_relative "support/organization_provider_keys"

# Organization and personal provider keys in the database, and the lookups
# that read by owner and provider: they see organization keys only, so a
# personal key never reaches a sandbox or a connection status.
class ProviderKeyScopeTest < ActionDispatch::IntegrationTest
  include OrganizationProviderKeys

  test "the database refuses a second organization key for one account and provider" do
    duplicate = ActionAgent::ProviderKey.new(provider: "anthropic", credential: "sk-ant-second", account_id: @account.id)

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "the database refuses a second personal key for one member, account and provider" do
    duplicate = ActionAgent::ProviderKey.new(
      provider: "anthropic", credential: "sk-ant-ada-2", account_id: @account.id, scope_key: "user:#{@ada.id}"
    )

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "an organization key and personal keys for the same provider are each valid" do
    assert @organization_key.valid?
    assert @ada_key.valid?
    assert_equal [ false, true, true ], [ @organization_key, @ada_key, @grace_key ].map(&:personal?)

    second = ActionAgent::ProviderKey.new(provider: "anthropic", credential: "sk-ant-x", account_id: @account.id, scope_key: "user:#{@ada.id}")
    assert_not second.valid?
    assert_includes second.errors[:provider], "has already been taken"
  end

  test "a personal key needs an account-owned install and is never a connection credential" do
    codex = ActionAgent::ProviderKey.new(provider: "codex", credential: "sk-codex", account_id: @account.id, scope_key: "user:#{@ada.id}")
    assert_not codex.valid?
    assert_match(/cannot be a personal key/, codex.errors[:provider].join)

    ActionAgent.account_class = nil
    per_user = ActionAgent::ProviderKey.new(provider: "openai", credential: "sk-x", user_id: @ada.id, scope_key: "user:#{@ada.id}")
    assert_not per_user.valid?
    assert_match(/owned per account/, per_user.errors[:scope_key].join)
  end

  test "for_owner and owned return only the organization key, personal_for only the member's own" do
    assert_equal [ @organization_key ], ActionAgent::ProviderKey.for_owner(@account).to_a
    assert_equal [ @ada_key ], ActionAgent::ProviderKey.personal_for(@account, @ada).to_a
    assert_equal [ @grace_key ], ActionAgent::ProviderKey.personal_for(@account, @grace).to_a

    get "/activeagents/api/provider_keys"
    row = provider_row("anthropic")
    assert_equal "sk-a…tion", row["hint"]
    assert_not_includes response.body, @ada_key.display_hint
    assert_not_includes response.body, @grace_key.display_hint
  end

  test "personal_for reads nothing for an actor that is not a user, or an owner that is not an account" do
    assert_empty ActionAgent::ProviderKey.personal_for(@account, Object.new)
    assert_empty ActionAgent::ProviderKey.personal_for(@account, nil)
    assert_empty ActionAgent::ProviderKey.personal_for(nil, @ada)

    ActionAgent.account_class = nil
    assert_empty ActionAgent::ProviderKey.personal_for(@account, @ada), "an install without accounts has no personal keys"
  end

  test "a personal key never reaches a sandbox, and Claude Code and Codex status read organization keys only" do
    # Refused by validation; written directly to stand for one that got in.
    %w[claude_code codex].each do |provider|
      credential = provider == "codex" ? "sk-codex-ada" : "sk-ant-api03-ada"
      ActionAgent::ProviderKey.new(provider: provider, credential: credential, account_id: @account.id,
                                   scope_key: "user:#{@ada.id}").save!(validate: false)
    end
    ActionAgent::GithubConnection.delete_all
    ActionAgent::GithubConnection.create!(
      access_token: "gho_organization", github_user_id: 42, login: "octocat", account_id: @account.id,
      repositories: [ { "id" => 1, "full_name" => "acme/web", "private" => true, "default_branch" => "main" } ]
    )
    sandbox = ActionAgent::SandboxSession.new(session_id: SecureRandom.uuid, sandbox_type: "app_runtime",
                                              repository: "acme/web", account_id: @account.id, user_id: @account.id)
    sandbox.save!(validate: false)

    assert_equal({}, sandbox.runtime_environment(runner: "claude_code"))
    assert_equal({}, sandbox.runtime_environment(runner: "codex"))
    assert_empty ActionAgent::MockSandboxBackend.new.create_sandbox(sandbox)[:environment_keys]

    get "/activeagents/api/sandboxes"
    assert_equal false, response.parsed_body["codex_connected"]
    assert_equal false, response.parsed_body["claude_code_connected"]

    key("claude_code", "sk-ant-api03-organization")
    assert_equal({ "ANTHROPIC_API_KEY" => "sk-ant-api03-organization" }, sandbox.runtime_environment(runner: "claude_code"))
    assert_equal [ "ANTHROPIC_API_KEY" ], ActionAgent::MockSandboxBackend.new.create_sandbox(sandbox)[:environment_keys]
  end
end
