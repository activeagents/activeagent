# frozen_string_literal: true

require "test_helper"

class DashboardAssistantApiTest < ActionDispatch::IntegrationTest
  def setup
    @original_credentials = ActionAgent.provider_credentials_resolver
    @original_config = ActiveAgent.configuration
    @original_auth = ActionAgent.authentication_method
    @original_user = ActionAgent.current_user_resolver
    @original_account = ActionAgent.current_account_resolver
    @original_multi_tenant = ActionAgent.multi_tenant
    @original_assistant = ActionAgent.assistant_enabled
    ActiveAgent.instance_variable_set(:@configuration, {})
    ActionAgent.provider_credentials_resolver = ->(_owner, _provider) { {} }
    @usage = []
    ActionAgent.usage_recorder = ->(owner, kind) { @usage << [ owner, kind ] }
  end

  def teardown
    ActionAgent.provider_credentials_resolver = @original_credentials
    ActiveAgent.instance_variable_set(:@configuration, @original_config)
    ActionAgent.authentication_method = @original_auth
    ActionAgent.current_user_resolver = @original_user
    ActionAgent.current_account_resolver = @original_account
    ActionAgent.multi_tenant = @original_multi_tenant
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.execution_enabled = true
    ActionAgent.assistant_enabled = @original_assistant
  end

  test "metadata discloses provider processing and unavailable integrations without selecting a provider" do
    get "/activeagents/api/dashboard_assistant"
    assert_response :success
    data = response.parsed_body
    assert_nil data.dig("defaults", "provider")
    assert data.dig("processing", "consent_required")
    assert_equal %w[openai anthropic ollama openrouter], data["providers"].map { |provider| provider["id"] }
    assert data["connections"].values.all? { |connection| connection == { "supported" => false } }
  end

  test "missing consent and credentials fail before recording usage" do
    post "/activeagents/api/dashboard_assistant", params: input.except(:allow_provider_processing), as: :json
    assert_response :unprocessable_entity
    assert_equal "processing_consent_required", response.parsed_body["code"]
    ActionAgent::ProviderKey.stub(:for_owner, ActionAgent::ProviderKey.none) do
      post "/activeagents/api/dashboard_assistant", params: input, as: :json
    end
    assert_response :service_unavailable
    assert_equal "setup_required", response.parsed_body["code"]
    assert_equal "/settings", response.parsed_body.dig("action", "path")
    assert_empty @usage
  end

  test "authentication owner execution and quota gates apply" do
    ActionAgent.authentication_method = ->(_controller) { false }
    post "/activeagents/api/dashboard_assistant", params: input, as: :json
    assert_response :unauthorized
    ActionAgent.authentication_method = nil
    ActionAgent.multi_tenant = true
    ActionAgent.current_account_resolver = ->(_controller) { nil }
    post "/activeagents/api/dashboard_assistant", params: input, as: :json
    assert_response :unauthorized
    ActionAgent.multi_tenant = false
    ActionAgent.execution_enabled = false
    post "/activeagents/api/dashboard_assistant", params: input, as: :json
    assert_response :forbidden
    ActionAgent.execution_enabled = true
    ActionAgent.quota_checker = ->(_owner, _kind) { "Out of runs" }
    post "/activeagents/api/dashboard_assistant", params: input, as: :json
    assert_response :payment_required
    assert_empty @usage
  end

  test "request supplies only browser fields while owner and execution usage are server controlled" do
    owner = Struct.new(:id).new(998)
    ActionAgent.current_user_resolver = ->(_controller) { owner }
    captured = nil
    fake = Object.new
    fake.define_singleton_method(:validate!) { self }
    fake.define_singleton_method(:call) { { answer: "Fixture response", cards: [], drafts: [], limitations: [] } }
    constructor = ->(**arguments) { captured = arguments; fake }
    ActionAgent::DashboardAssistantService.stub(:new, constructor) do
      post "/activeagents/api/dashboard_assistant", params: input.merge(owner: { id: 999 }, cards: [ "forged" ]), as: :json
    end
    assert_response :success
    assert_same owner, captured[:owner]
    assert_not captured.key?(:cards)
    assert_equal [ [ owner, :execution ] ], @usage
    assert_empty response.parsed_body["cards"]
  end

  test "provider errors are redacted and do not become simulated answers" do
    fake = Object.new
    fake.define_singleton_method(:validate!) { self }
    fake.define_singleton_method(:call) { raise "secret-fixture-key and request body" }
    ActionAgent::DashboardAssistantService.stub(:new, fake) do
      post "/activeagents/api/dashboard_assistant", params: input, as: :json
    end
    assert_response :bad_gateway
    assert_equal "generation_failed", response.parsed_body["code"]
    assert_not_includes response.body, "secret-fixture-key"
    assert_nil response.parsed_body["answer"]
  end

  test "both endpoints refuse where the assistant is not a development or CI tool" do
    ActionAgent.assistant_enabled = false
    get "/activeagents/api/dashboard_assistant"
    assert_response :forbidden
    assert_equal "assistant_disabled", response.parsed_body["code"]
    post "/activeagents/api/dashboard_assistant", params: input, as: :json
    assert_response :forbidden
    assert_equal "assistant_disabled", response.parsed_body["code"]
    assert_empty @usage
    # An explicit true carries the decision into an environment that would
    # otherwise be refused; nil follows Rails.env, which is test here.
    ActionAgent.assistant_enabled = true
    get "/activeagents/api/dashboard_assistant"
    assert_response :success
    ActionAgent.assistant_enabled = nil
    get "/activeagents/api/dashboard_assistant"
    assert_response :success
  end

  test "the dashboard page tells the browser whether it has an assistant" do
    get "/activeagents"
    assert_response :success
    assert_equal true, dashboard_props.dig("meta", "assistantEnabled")
    ActionAgent.assistant_enabled = false
    get "/activeagents"
    assert_response :success
    assert_equal false, dashboard_props.dig("meta", "assistantEnabled")
  end

  test "assistant POST requires a real dashboard CSRF token when protection is enabled" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    # A cross-site POST with no token is rejected by both forgery protection
    # schemes: the token check Rails verifies through 8.1, and the
    # Sec-Fetch-Site check Rails 8.2 verifies instead. Rails 8.2 accepts a
    # header-less plain-HTTP request as a non-browser caller, so a request
    # missing only the token would pass there and prove nothing.
    post "/activeagents/api/dashboard_assistant", params: input, headers: { "Sec-Fetch-Site" => "cross-site" }, as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_csrf_token", response.parsed_body["code"]
    get "/activeagents"
    token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"]
    post "/activeagents/api/dashboard_assistant", params: input.except(:allow_provider_processing), headers: { "X-CSRF-Token" => token }, as: :json
    assert_response :unprocessable_entity
    assert_equal "processing_consent_required", response.parsed_body["code"]
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  private

  # The dashboard page hands the React app its props in a data attribute.
  def dashboard_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("#active-agent-dashboard")["data-props"])
  end

  def input
    { message: "Prepare a catalog helper", history: [], provider: "openai", model: "gpt-5.1", allow_provider_processing: true }
  end
end
