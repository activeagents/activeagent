# frozen_string_literal: true

require "test_helper"

class ClaudeLoginsApiTest < ActionDispatch::IntegrationTest
  class Backend < ActionAgent::LocalSandboxBackend
    class << self
      attr_accessor :calls, :status
    end
    def start_claude_login(sandbox)
      self.class.calls << [ :start, sandbox.id ]
      { status: "awaiting_code", authorize_url: "https://claude.ai/oauth/authorize?client_id=fixture", logged_in: false }
    end
    def submit_claude_login_code(sandbox, _code)
      self.class.calls << [ :submit, sandbox.id ]
      { status: "connected", logged_in: true, auth_method: "claude.ai" }
    end
    def claude_login_status(*) = self.class.status || { status: "connected", logged_in: true, auth_method: "claude.ai" }
    def claude_logout(sandbox) = self.class.calls << [ :logout, sandbox.id ]
  end

  def setup
    @saved = %i[sandbox_service sandbox_backends claude_code_auth user_class current_user_resolver account_class current_account_resolver multi_tenant].index_with { |key| ActionAgent.public_send(key) }
    ActionAgent.sandbox_backends = { "login_fixture" => Backend.name }
    ActionAgent.sandbox_service = :login_fixture
    ActionAgent.claude_code_auth = :sandbox_login
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true
    @user = User.create!(name: "Fixture owner", email: "owner-#{SecureRandom.hex(4)}@example.com", age: 30)
    @other = User.create!(name: "Fixture member", email: "member-#{SecureRandom.hex(4)}@example.com", age: 30)
    @account = User.create!(name: "Fixture account", email: "account-#{SecureRandom.hex(4)}@example.com", age: 30)
    current = @user
    account = @account
    ActionAgent.current_user_resolver = ->(_) { current }
    ActionAgent.current_account_resolver = ->(_) { account }
    ActionAgent::GithubConnection.create!(access_token: "gho_synthetic", github_user_id: 42, login: "fixture", account_id: @account.id, repositories: [ { "id" => 1, "full_name" => "fixture/support", "default_branch" => "main" } ])
    @sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "fixture/support", user_id: @user.id, account_id: @account.id)
    @sandbox.mark_ready!(cloud_run_url: "http://127.0.0.1:9999")
    Backend.calls = []
  end

  def teardown
    Backend.status = nil
    @saved.each { |key, value| ActionAgent.public_send("#{key}=", value) }
  end

  test "the signed-in user starts and completes a login whose code is never returned or stored" do
    post path
    assert_response :accepted, response.body
    assert_equal @user.id, @sandbox.reload.claude_login_user_id
    post "#{path}/code", params: { claude_login_code: "fixture-one-use-code" }, as: :json
    assert_response :success, response.body
    refute_includes response.body, "fixture-one-use-code"
    refute_includes @sandbox.reload.attributes.to_json, "fixture-one-use-code"
    assert_equal [ [ :start, @sandbox.id ], [ :submit, @sandbox.id ] ], Backend.calls
    assert_equal "no-store", response.headers["Cache-Control"]
    filters = Rails.application.config.filter_parameters
    assert_equal "[FILTERED]", ActiveSupport::ParameterFilter.new(filters).filter("claude_login_code" => "fixture")["claude_login_code"]
    delete path
    assert_response :success
    assert_nil @sandbox.reload.claude_login_user_id
  end

  test "another account member cannot use, replace, finish or disconnect a personal login" do
    @sandbox.update!(claude_login_user_id: @other.id)
    get path
    assert_response :success
    assert_equal false, JSON.parse(response.body).dig("login", "logged_in")
    post path
    assert_response :conflict
    post "#{path}/code", params: { claude_login_code: "fixture" }, as: :json
    assert_response :forbidden
    delete path
    assert_response :forbidden
    assert_empty Backend.calls
    assert_nil ActionAgent::ClaudeCodeAuth.credential_mode(@sandbox, user_id: @user.id)
    # Not even the account's API key: the session would run beside the other
    # member's CLAUDE_CONFIG_DIR as the same OS user.
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: "sk-ant-api03-accountFixture", account_id: @account.id)
    assert_nil ActionAgent::ClaudeCodeAuth.credential_mode(@sandbox, user_id: @user.id)
    assert_match(/Another member is signed in/, ActionAgent::ClaudeCodeAuth.credential_refusal(@sandbox, user_id: @user.id))
    assert_nil ActionAgent::ClaudeCodeAuth.sandbox_status(@sandbox, user_id: @user.id)[:credential_mode]
    assert_equal "sandbox_login", ActionAgent::ClaudeCodeAuth.credential_mode(@sandbox, user_id: @other.id)
    @sandbox.update!(claude_login_user_id: nil)
    assert_equal "api_key", ActionAgent::ClaudeCodeAuth.credential_mode(@sandbox, user_id: @user.id)
  end

  test "no other member's session of any runner runs beside a personal login" do
    @sandbox.update!(claude_login_user_id: @other.id)
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: "sk-ant-api03-accountFixture", account_id: @account.id)
    %w[claude_code codex].each do |runner|
      post "/activeagents/api/sandboxes/#{@sandbox.session_id}/code_sessions", params: { prompt: "Read the other login", runner: runner }, as: :json
      assert_response :unprocessable_entity, runner
      assert_match(/Another member is signed in/, response.parsed_body["error"])
    end
    assert_equal 0, @sandbox.code_sessions.count
  end

  test "a sign-in that ended without a login stops holding the sandbox" do
    @sandbox.update!(claude_login_user_id: @other.id)
    Backend.status = { status: "awaiting_code", logged_in: false, auth_method: nil }
    post path
    assert_response :conflict
    Backend.status = { status: "completed", logged_in: false, auth_method: nil }
    post path
    assert_response :conflict, "a completed CLI may hold another kind of credential until logout"
    Backend.status = { status: "expired", logged_in: false, auth_method: nil }
    post path
    assert_response :accepted, response.body
    assert_equal @user.id, @sandbox.reload.claude_login_user_id
    get path
    assert_response :success
    assert_nil @sandbox.reload.claude_login_user_id
    assert_equal "expired", response.parsed_body.dig("login", "status")
  end

  test "a host backend's own error answers with the fixed message, never its text" do
    @sandbox.update!(claude_login_user_id: nil)
    Backend.class_eval { alias_method :original_start, :start_claude_login }
    Backend.define_method(:start_claude_login) { |_sandbox| raise IOError, "container sandbox-1 said: secret detail" }
    begin
      post path
    ensure
      Backend.class_eval do
        alias_method :start_claude_login, :original_start
        remove_method :original_start
      end
    end
    assert_response :unprocessable_entity
    assert_equal "Claude sign-in could not complete. Check that Claude Code is installed, then start again.", response.parsed_body["error"]
    refute_includes response.body, "secret detail"
    assert_nil @sandbox.reload.claude_login_user_id
  end

  test "a running session prevents changing its authentication" do
    @sandbox.update!(claude_login_user_id: @user.id)
    @sandbox.code_sessions.create!(prompt: "A synthetic fix", status: :running)
    post path
    assert_response :conflict
    delete path
    assert_response :conflict
    assert_empty Backend.calls
  end

  test "an expired sandbox and an unsupported mode cannot start login" do
    @sandbox.update!(expires_at: 1.minute.ago)
    post path
    assert_response :unprocessable_entity
    ActionAgent.claude_code_auth = :api_key
    post path
    assert_response :unprocessable_entity
    assert_empty Backend.calls
  end

  private

  def path = "/activeagents/api/sandboxes/#{@sandbox.session_id}/claude_login"
end
