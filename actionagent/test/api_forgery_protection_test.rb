# frozen_string_literal: true

require "test_helper"

# The dashboard API authenticates with the host's session cookie, so it keeps
# forgery protection on (#461). Endpoints authenticated by a bearer token have
# no cookie to ride on and stay exempt.
class ApiForgeryProtectionTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
    @original_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  def teardown
    ActionController::Base.allow_forgery_protection = @original_forgery_protection
  end

  # A cross-site POST with no token is rejected by both forgery protection
  # schemes: the token check Rails verifies through 8.1, and the
  # Sec-Fetch-Site check Rails 8.2 verifies instead.
  CROSS_SITE = { "Sec-Fetch-Site" => "cross-site" }.freeze
  AGENT = { agent: { name: "Forged", provider: "openai", model: "gpt-4o-mini" } }.freeze

  test "a cross-site write to the dashboard API is refused with the dashboard's JSON" do
    post "/activeagents/api/agents", params: AGENT, headers: CROSS_SITE, as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_csrf_token", response.parsed_body["code"]
    assert_equal 0, ActionAgent::Agent.count
  end

  test "the same write succeeds with the page's CSRF token" do
    get "/activeagents"
    token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"]

    post "/activeagents/api/agents", params: AGENT, headers: { "X-CSRF-Token" => token }, as: :json

    assert_response :created
    assert_equal 1, ActionAgent::Agent.count
  end

  test "the MCP facade authenticates by bearer token and stays exempt" do
    key = ActionAgent::ApiKey.create!(name: "Test key")

    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "initialize" },
      headers: CROSS_SITE.merge("Authorization" => "Bearer #{key.token}"),
      as: :json

    assert_response :success
    assert_equal "2025-03-26", response.parsed_body.dig("result", "protocolVersion")
  end
end
