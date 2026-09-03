# frozen_string_literal: true

require "test_helper"

# Credentials on a host that never ran `rails db:encryption:init` (#387): the
# engine derives encryption keys, so API keys and provider credentials can be
# created and the MCP facade can authenticate. Also the live Anthropic model
# lookup, which called a helper the engine never defined (#390).
class CredentialsTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::ApiKey.delete_all
    ActionAgent::ProviderKey.delete_all
    ActionAgent::Agent.delete_all
  end

  test "the host's encryption keys are derived when it configured none" do
    config = Rails.application.config.active_record.encryption

    assert config.primary_key.present?
    assert config.deterministic_key.present?
    assert config.key_derivation_salt.present?
    assert ActiveRecord::Encryption.config.primary_key.present?
  end

  test "an API key can be created and authenticates the MCP facade" do
    post "/activeagents/api/api_keys", params: { name: "mcp-probe" }

    assert_response :created
    token = JSON.parse(response.body).dig("api_key", "token")
    assert token.start_with?("aa_")
    assert_equal 1, ActionAgent::ApiKey.count

    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "initialize" },
      headers: { "Authorization" => "Bearer #{token}" },
      as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "2025-03-26", body.dig("result", "protocolVersion")

    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 2, method: "initialize" },
      headers: { "Authorization" => "Bearer aa_not_a_real_token" },
      as: :json

    assert_response :unauthorized
  end

  test "a provider credential can be stored and is never rendered back" do
    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-test-secret-123" }

    assert_response :created
    assert_not_includes response.body, "sk-test-secret-123"
    assert_equal "sk-test-secret-123", ActionAgent::ProviderKey.find_by!(provider: "openai").credential
  end

  test "the live Anthropic model lookup queries the API with the owner's key" do
    ActionAgent::ProviderKey.create!(provider: "anthropic", credential: "sk-ant-test")
    stub_request(:get, "https://api.anthropic.com/v1/models?limit=50")
      .with(headers: { "x-api-key" => "sk-ant-test" })
      .to_return(status: 200, body: { data: [ { id: "claude-sonnet-5" }, { id: "claude-opus-5" } ] }.to_json,
                 headers: { "Content-Type" => "application/json" })

    get "/activeagents/api/provider_models", params: { provider: "anthropic" }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "live", body["source"], "the lookup fell back to the curated list: #{body.inspect}"
    assert_equal %w[claude-sonnet-5 claude-opus-5], body["models"]
  end

  test "the Anthropic lookup falls back to the curated list without a key" do
    get "/activeagents/api/provider_models", params: { provider: "anthropic" }

    assert_response :success
    assert_equal "curated", JSON.parse(response.body)["source"]
  end
end
