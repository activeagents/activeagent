# frozen_string_literal: true

require "test_helper"
require_relative "support/organization_provider_keys"

# The provider keys API in either scope, the members list and the dashboard
# settings for both.
class ProviderKeysApiTest < ActionDispatch::IntegrationTest
  include OrganizationProviderKeys

  test "the index carries scope, effective source, who set each key and when" do
    ActionAgent.provider_key_scope = :personal_override
    @organization_key.update!(set_by_id: @grace.id)

    get "/activeagents/api/provider_keys"
    body = response.parsed_body
    assert_equal "organization", body["scope"]
    assert_equal true, body["personal_keys_enabled"]
    assert_equal true, body["can_manage_organization_keys"]
    row = provider_row("anthropic")
    assert_equal "organization", row["scope"]
    assert_equal "personal", row["effective_source"], "Ada's own runs use her key"
    assert_equal({ "id" => @grace.id, "name" => "Grace" }, row["set_by"])
    assert_equal @organization_key.reload.updated_at.iso8601, row["updated_at"]
    assert_nil provider_row("openai")["set_by"]
    assert_nil provider_row("codex")["effective_source"]

    get "/activeagents/api/provider_keys", params: { scope: "personal" }
    assert_equal "personal", response.parsed_body["scope"]
    assert_equal "sk-a…-ada", provider_row("anthropic")["hint"]
    assert_not_includes response.body, @grace_key.display_hint
    assert_not_includes response.body, @organization_key.display_hint
  end

  test "an unknown scope is refused" do
    get "/activeagents/api/provider_keys", params: { scope: "everyone" }

    assert_response :unprocessable_entity
  end

  test "organization writes ask :manage_credentials and record who saved them" do
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_credentials }

    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-denied", scope: "organization" }
    assert_response :forbidden
    delete "/activeagents/api/provider_keys/anthropic"
    assert_response :forbidden
    assert ActionAgent::ProviderKey.exists?(@organization_key.id)
    get "/activeagents/api/provider_keys"
    assert_equal false, response.parsed_body["can_manage_organization_keys"]

    ActionAgent.permission_checker = nil
    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-allowed" }
    assert_response :created
    assert_equal @ada.id, ActionAgent::ProviderKey.for_owner(@account).find_by!(provider: "openai").set_by_id
  end

  test "under :personal_override any member changes only their own personal key, with no permission asked" do
    ActionAgent.provider_key_scope = :personal_override
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_credentials }

    post "/activeagents/api/provider_keys", params: { provider: "anthropic", credential: "sk-ant-ada-new", scope: "personal" }
    assert_response :created, response.body
    assert_equal "sk-ant-ada-new", @ada_key.reload.credential
    assert_equal @ada.id, @ada_key.set_by_id
    assert_equal "sk-ant-grace", @grace_key.reload.credential
    assert_equal "sk-ant-organization", @organization_key.reload.credential

    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-ada-openai", scope: "personal" }
    assert_response :created
    assert_equal "user:#{@ada.id}", ActionAgent::ProviderKey.personal_for(@account, @ada).find_by!(provider: "openai").scope_key

    delete "/activeagents/api/provider_keys/anthropic", params: { scope: "personal" }
    assert_response :no_content
    assert_not ActionAgent::ProviderKey.exists?(@ada_key.id)
    assert ActionAgent::ProviderKey.exists?(@grace_key.id)
    assert ActionAgent::ProviderKey.exists?(@organization_key.id)

    delete "/activeagents/api/provider_keys/anthropic", params: { scope: "personal" }
    assert_response :not_found, "Ada has no personal Anthropic key left; Grace's is not hers to delete"
  end

  test "a save that loses a race for the same key updates the row the other request saved" do
    ActionAgent.provider_key_scope = :personal_override
    real = ActionAgent::ProviderKey.method(:personal_for)
    other_request = -> { key("openai", "sk-ada-other-tab", member: @ada) }
    raced = false
    racing = lambda do |owner, actor|
      relation = SimpleDelegator.new(real.call(owner, actor))
      relation.define_singleton_method(:find_or_initialize_by) do |**attributes|
        record = __getobj__.find_or_initialize_by(**attributes)
        unless raced
          raced = true
          other_request.call
          record.define_singleton_method(:update!) { |**| raise ActiveRecord::RecordNotUnique, "duplicate key" }
        end
        record
      end
      relation
    end

    ActionAgent::ProviderKey.stub(:personal_for, racing) do
      post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-ada-this-tab", scope: "personal" }
    end

    assert_response :created, response.body
    assert_equal [ "sk-ada-this-tab" ], ActionAgent::ProviderKey.personal_for(@account, @ada).where(provider: "openai").map(&:credential)
  end

  test "a personal Claude Code or Codex key is refused" do
    ActionAgent.provider_key_scope = :personal_override

    post "/activeagents/api/provider_keys", params: { provider: "claude_code", credential: "sk-ant-api03-ada", scope: "personal" }
    assert_response :unprocessable_entity
    post "/activeagents/api/provider_keys", params: { provider: "codex", credential: "sk-codex-ada", scope: "personal" }
    assert_response :unprocessable_entity
    assert_empty ActionAgent::ProviderKey.personal_for(@account, @ada).where(provider: %w[claude_code codex])
  end

  test "personal writes are refused when personal keys are off" do
    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-ada", scope: "personal" }
    assert_response :unprocessable_entity
    assert_equal "personal_keys_disabled", response.parsed_body["code"]
    delete "/activeagents/api/provider_keys/anthropic", params: { scope: "personal" }
    assert_response :unprocessable_entity
    assert ActionAgent::ProviderKey.exists?(@ada_key.id)

    ActionAgent.provider_key_scope = :personal_override
    ActionAgent.account_class = nil
    ActionAgent.multi_tenant = false
    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-ada", scope: "personal" }
    assert_response :unprocessable_entity, "an install without accounts has no personal keys"
  end

  test "a personal write is refused when the owner does not resolve to an account" do
    ActionAgent.provider_key_scope = :personal_override
    ActionAgent.account_class = "Post"
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_credentials }

    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-probe", scope: "personal" }

    assert_response :unprocessable_entity
    assert_equal "personal_keys_disabled", response.parsed_body["code"]
    assert_not ActionAgent::ProviderKey.unscoped.exists?(provider: "openai"), "no ownerless row is saved"
  end

  test "a connection test sends the stored key only to the stored host" do
    key("ollama", "http://ollama.organization:11434", api_key: "sk-ollama-organization")
    stored = stub_request(:get, "http://ollama.organization:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-ollama-organization" })
      .to_return(status: 200, body: { data: [] }.to_json)
    stub_request(:get, "http://elsewhere.example:11434/v1/models").to_return(status: 200, body: { data: [] }.to_json)

    post "/activeagents/api/provider_keys/test", params: { provider: "ollama", credential: "http://elsewhere.example:11434" }
    assert_requested(:get, "http://elsewhere.example:11434/v1/models") { |request| !request.headers.key?("Authorization") }

    post "/activeagents/api/provider_keys/test", params: { provider: "ollama" }
    assert_requested stored, times: 1
    post "/activeagents/api/provider_keys/test", params: { provider: "ollama", credential: "http://ollama.organization:11434/v1/" }
    assert_requested stored, times: 2

    WebMock.reset!
    typed = stub_request(:get, "http://elsewhere.example:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-typed" })
      .to_return(status: 200, body: { data: [] }.to_json)
    post "/activeagents/api/provider_keys/test", params: { provider: "ollama", credential: "http://elsewhere.example:11434", api_key: "sk-typed" }
    assert_requested typed
  end

  test "a member's connection test sends their stored key only to their stored host" do
    ActionAgent.provider_key_scope = :personal_override
    key("ollama", "http://ollama.organization:11434", api_key: "sk-ollama-organization")
    key("ollama", "http://ollama.ada:11434", api_key: "sk-ollama-ada", member: @ada)
    key("ollama", "http://ollama.grace:11434", api_key: "sk-ollama-grace", member: @grace)
    own = stub_request(:get, "http://ollama.ada:11434/v1/models")
      .with(headers: { "Authorization" => "Bearer sk-ollama-ada" })
      .to_return(status: 200, body: { data: [] }.to_json)
    stub_request(:get, "http://ollama.organization:11434/v1/models").to_return(status: 200, body: { data: [] }.to_json)

    post "/activeagents/api/provider_keys/test", params: { provider: "ollama", scope: "personal" }
    assert_requested own

    post "/activeagents/api/provider_keys/test",
      params: { provider: "ollama", scope: "personal", credential: "http://ollama.organization:11434" }
    assert_requested(:get, "http://ollama.organization:11434/v1/models") { |request| !request.headers.key?("Authorization") }
  end

  test "a personal Ollama host asks :manage_credentials, and removing one's own does not" do
    ActionAgent.provider_key_scope = :personal_override
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_credentials }

    post "/activeagents/api/provider_keys/test",
      params: { provider: "ollama", scope: "personal", credential: "http://10.0.0.5:8080" }
    assert_response :forbidden
    assert_not_requested :get, "http://10.0.0.5:8080/v1/models"

    post "/activeagents/api/provider_keys", params: { provider: "ollama", scope: "personal", credential: "http://10.0.0.5:8080" }
    assert_response :forbidden
    assert_empty ActionAgent::ProviderKey.personal_for(@account, @ada).where(provider: "ollama")

    get "/activeagents/api/provider_keys", params: { scope: "personal" }
    assert_equal [ true, false, false ], %w[openai ollama claude_code].map { |provider| provider_row(provider)["editable"] }

    held = key("ollama", "http://ollama.ada:11434", member: @ada)
    delete "/activeagents/api/provider_keys/ollama", params: { scope: "personal" }
    assert_response :no_content
    assert_not ActionAgent::ProviderKey.exists?(held.id)
  end

  test "the checker sees the personal key it is asked about" do
    ActionAgent.provider_key_scope = :personal_override
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.scope_key ] if action == :manage_credentials
      subject.personal?
    end

    post "/activeagents/api/provider_keys", params: { provider: "ollama", scope: "personal", credential: "http://ollama.ada:11434" }

    assert_response :created
    assert_includes asked, [ :manage_credentials, "user:#{@ada.id}" ]
    get "/activeagents/api/provider_keys"
    assert_equal [ false, false ], %w[openai ollama].map { |provider| provider_row(provider)["editable"] }
  end

  test "the members list renders only id, name, email and role from the resolver" do
    ActionAgent.members_resolver = lambda do |owner|
      [ { id: 1, name: "Ada", email: "ada@example.com", role: "admin", token: "secret", owner_id: owner.id } ]
    end

    get "/activeagents/api/members"

    assert_response :success
    assert_equal [ { "id" => 1, "name" => "Ada", "email" => "ada@example.com", "role" => "admin" } ], response.parsed_body["members"]
  end

  test "without a members resolver, or with one that raises, the list is the signed-in user" do
    get "/activeagents/api/members"
    signed_in = [ { "id" => @ada.id, "name" => "Ada", "email" => @ada.email, "role" => nil } ]
    assert_equal signed_in, response.parsed_body["members"]

    ActionAgent.members_resolver = ->(_owner) { raise "directory down" }
    get "/activeagents/api/members"
    assert_equal signed_in, response.parsed_body["members"]
  end

  test "the dashboard learns the key scope and the invite link" do
    ActionAgent.provider_key_scope = :personal_override
    ActionAgent.member_invite_url = "/team/invitations/new"

    get "/activeagents"

    meta = JSON.parse(css_select("[data-props]").first["data-props"])["meta"]
    assert_equal "personal_override", meta["providerKeyScope"]
    assert_equal true, meta["personalProviderKeys"]
    assert_equal "/team/invitations/new", meta["memberInviteUrl"]
  end

  test "provider_key_scope accepts the documented values and reset! clears it" do
    ActionAgent.provider_key_scope = "personal_override"
    assert_equal :personal_override, ActionAgent.provider_key_scope
    assert_raises(ArgumentError) { ActionAgent.provider_key_scope = :everyone }

    original = ActionAgent.instance_variables.to_h { |name| [ name, ActionAgent.instance_variable_get(name) ] }
    ActionAgent.reset!
    assert_equal :organization, ActionAgent.provider_key_scope
    assert_nil ActionAgent.members_resolver
    assert_nil ActionAgent.member_invite_url
  ensure
    original&.each { |name, value| ActionAgent.instance_variable_set(name, value) }
  end
end
