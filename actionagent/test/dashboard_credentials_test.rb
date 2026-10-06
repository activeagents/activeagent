# frozen_string_literal: true

require "test_helper"

# The dashboard page carries no credential, since anything that reads its
# markup reads the props. The Organization view reads the telemetry key from
# its own endpoint.
class DashboardCredentialsTest < ActionDispatch::IntegrationTest
  PROVIDER_KEY = "sk-page-provider-key-0123456789"
  TELEMETRY_KEY = "tk-page-telemetry-key-0123456789"

  def setup
    ActionAgent::ProviderKey.delete_all
    ActionAgent::ApiKey.delete_all
    User.delete_all
  end

  def teardown
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
  end

  # A user of a tenant whose telemetry key is TELEMETRY_KEY. The dummy app has
  # no Account, so the tenant is a User.
  def sign_in_to_account
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true
    @me = create_user("me")
    @account = create_user("account")
    @account.define_singleton_method(:telemetry_api_key) { TELEMETRY_KEY }
    ActionAgent.current_user_resolver = ->(_controller) { @me }
    ActionAgent.current_account_resolver = ->(_controller) { @account }
  end

  def create_user(name)
    User.create!(email: "#{name}-#{SecureRandom.hex(3)}@example.com", name: name.capitalize, age: 30)
  end

  test "the dashboard page carries no credential" do
    sign_in_to_account
    ActionAgent::ProviderKey.create!(provider: "openai", credential: PROVIDER_KEY, user_id: @account.id)
    api_key = ActionAgent::ApiKey.create!(name: "ci", user_id: @account.id)

    get "/activeagents/dashboard"

    assert_response :success
    props = Nokogiri::HTML(response.body).at("#active-agent-dashboard")["data-props"]
    [ TELEMETRY_KEY, PROVIDER_KEY, api_key.token, "telemetry_api_key" ].each do |secret|
      assert_not_includes props, secret
    end
    assert_equal({ "id" => @account.id, "name" => "Account" }, JSON.parse(props)["account"])
  end

  test "the Organization view reads the telemetry key from its own endpoint, uncached" do
    sign_in_to_account

    get "/activeagents/api/telemetry_key"

    assert_response :success
    assert_equal TELEMETRY_KEY, response.parsed_body["telemetry_api_key"]
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "the telemetry key endpoint needs a tenant in a multi-tenant install" do
    sign_in_to_account
    ActionAgent.current_account_resolver = ->(_controller) { nil }

    get "/activeagents/api/telemetry_key"

    assert_response :unauthorized
    assert_not_includes response.body, TELEMETRY_KEY
  end

  test "the telemetry key is null for an owner without one" do
    ActionAgent.user_class = "User"
    me = create_user("me")
    ActionAgent.current_user_resolver = ->(_controller) { me }

    get "/activeagents/api/telemetry_key"

    assert_response :success
    assert_nil response.parsed_body["telemetry_api_key"]
  end
end
