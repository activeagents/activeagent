# frozen_string_literal: true

require "test_helper"

# ActionAgent.permission_checker: the host's answer to whether the signed-in
# user may perform a privileged action, and the endpoints that ask it.
class PermissionCheckerTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::ApiKey.delete_all
    ActionAgent::ProviderKey.delete_all
    ActionAgent::GithubConnection.delete_all
    ActionAgent.github_client_id = "client-id"
    ActionAgent.github_client_secret = "client-secret"
    @asked = []
  end

  def teardown
    ActionAgent.permission_checker = nil
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.github_client_id = nil
    ActionAgent.github_client_secret = nil
  end

  test "the vocabulary is fixed" do
    assert_equal %i[
      manage_credentials manage_github manage_api_keys publish_pull_request answer_input_request
      manage_project_secrets take_over_browser manage_recordings replace_scenarios
    ], ActionAgent::PERMISSION_ACTIONS
  end

  test "every action is allowed when no checker is configured" do
    ActionAgent::PERMISSION_ACTIONS.each do |action|
      assert ActionAgent.permitted?(nil, action), "#{action} single-tenant"
    end

    ActionAgent.multi_tenant = true
    ActionAgent::PERMISSION_ACTIONS.each do |action|
      assert ActionAgent.permitted?(nil, action), "#{action} multi-tenant"
    end
  end

  test "a multi-tenant install with no checker is warned about" do
    assert_not ActionAgent.warn_about_unchecked_permissions, "single-tenant"

    ActionAgent.multi_tenant = true
    logged = capture_log { assert ActionAgent.warn_about_unchecked_permissions }
    assert_match(/multi_tenant is on and no permission_checker is configured/, logged)

    ActionAgent.permission_checker = ->(*) { true }
    assert_not ActionAgent.warn_about_unchecked_permissions, "multi-tenant with a checker"
  end

  test "an unknown action raises, with or without a checker" do
    assert_raises(ArgumentError) { ActionAgent.permitted?(nil, :manage_everything) }
    assert_raises(ArgumentError) { ActionAgent.permitted?(nil, "manage_credentials") }

    ActionAgent.permission_checker = ->(*) { true }
    error = assert_raises(ArgumentError) { ActionAgent.permitted?(nil, :manage_everything) }
    assert_match(/manage_credentials/, error.message, "the message lists the known actions")
  end

  test "the checker receives the user, the action and the subject" do
    user = Object.new
    subject = Object.new
    ActionAgent.permission_checker = ->(*args) { @asked << args; true }

    assert ActionAgent.permitted?(user, :manage_github, subject)
    assert_equal [ [ user, :manage_github, subject ] ], @asked
  end

  test "a truthy answer allows and false denies" do
    answer = :yes
    ActionAgent.permission_checker = ->(*) { answer }

    assert ActionAgent.permitted?(Object.new, :manage_api_keys)
    answer = false
    assert_not ActionAgent.permitted?(Object.new, :manage_api_keys)

    ActionAgent.multi_tenant = true
    answer = :yes
    assert ActionAgent.permitted?(Object.new, :manage_api_keys)
    answer = false
    assert_not ActionAgent.permitted?(Object.new, :manage_api_keys)
  end

  test "a nil answer allows in single-tenant mode and denies in multi-tenant mode" do
    ActionAgent.permission_checker = ->(*) { nil }

    assert ActionAgent.permitted?(Object.new, :manage_credentials)

    ActionAgent.multi_tenant = true
    assert_not ActionAgent.permitted?(Object.new, :manage_credentials)
  end

  test "a missing user denies in multi-tenant mode without asking the checker" do
    ActionAgent.permission_checker = ->(*args) { @asked << args; true }
    ActionAgent.multi_tenant = true

    assert_not ActionAgent.permitted?(nil, :manage_credentials)
    assert_empty @asked
  end

  test "a missing user is passed to the checker in single-tenant mode" do
    ActionAgent.permission_checker = ->(*args) { @asked << args; true }

    assert ActionAgent.permitted?(nil, :manage_credentials)
    assert_equal [ [ nil, :manage_credentials, nil ] ], @asked
  end

  test "a checker that raises denies in either mode, and is logged" do
    ActionAgent.permission_checker = ->(*) { raise "policy service unavailable" }

    logged = capture_log { assert_not ActionAgent.permitted?(Object.new, :manage_github) }
    assert_match(/permission_checker raised for manage_github.*policy service unavailable/, logged)

    ActionAgent.multi_tenant = true
    assert_not ActionAgent.permitted?(Object.new, :manage_github)
  end

  test "a denied provider key write, test or delete answers 403 and changes nothing" do
    stored = ActionAgent::ProviderKey.create!(provider: "ollama", credential: "http://ollama.internal:11434")
    host = stored.credential
    deny(:manage_credentials)

    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-denied" }
    assert_forbidden(:manage_credentials)
    assert_nil ActionAgent::ProviderKey.find_by(provider: "openai")

    post "/activeagents/api/provider_keys", params: { provider: "ollama", credential: "http://elsewhere:11434" }
    assert_forbidden(:manage_credentials)
    assert_equal host, stored.reload.credential

    post "/activeagents/api/provider_keys/test", params: { provider: "ollama" }
    assert_forbidden(:manage_credentials)

    delete "/activeagents/api/provider_keys/ollama"
    assert_forbidden(:manage_credentials)
    assert ActionAgent::ProviderKey.exists?(stored.id)
  end

  test "a provider key write asks about the key it would change" do
    ActionAgent.permission_checker = ->(*args) { @asked << args; true }

    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-allowed" }

    assert_response :created
    (_user, action, subject), = @asked
    assert_equal :manage_credentials, action
    assert_kind_of ActionAgent::ProviderKey, subject
    assert_equal "openai", subject.provider
  end

  test "reading provider keys is not a managed action" do
    deny(:manage_credentials)

    get "/activeagents/api/provider_keys"

    assert_response :success
  end

  test "a denied API key create or revoke answers 403 and changes nothing" do
    existing = ActionAgent::ApiKey.create!(name: "ci")
    deny(:manage_api_keys)

    post "/activeagents/api/api_keys", params: { name: "denied" }
    assert_forbidden(:manage_api_keys)
    assert_not ActionAgent::ApiKey.exists?(name: "denied")

    delete "/activeagents/api/api_keys/#{existing.id}"
    assert_forbidden(:manage_api_keys)
    assert ActionAgent::ApiKey.exists?(existing.id)

    get "/activeagents/api/api_keys"
    assert_response :success
  end

  test "an API key create asks about the unsaved key" do
    ActionAgent.permission_checker = ->(*args) { @asked << args; true }

    post "/activeagents/api/api_keys", params: { name: "allowed" }

    assert_response :created
    (_user, action, subject), = @asked
    assert_equal :manage_api_keys, action
    assert_kind_of ActionAgent::ApiKey, subject
    assert_equal "allowed", subject.name
  end

  test "a denied GitHub selection change or disconnect answers 403 and changes nothing" do
    selected = [ { "id" => 7, "full_name" => "acme/web", "private" => true, "default_branch" => "main" } ]
    connection = ActionAgent::GithubConnection.create!(
      access_token: "gho_secret", github_user_id: 42, login: "octocat", scopes: "repo", repositories: selected
    )
    deny(:manage_github)

    patch "/activeagents/api/github_connection", params: { repositories: [] }, as: :json
    assert_forbidden(:manage_github)
    assert_equal [ "acme/web" ], connection.reload.repository_names

    delete "/activeagents/api/github_connection"
    assert_forbidden(:manage_github)
    assert ActionAgent::GithubConnection.exists?(connection.id)

    get "/activeagents/api/github_connection"
    assert_response :success
  end

  test "a denied GitHub connect returns to Settings without starting the OAuth flow" do
    deny(:manage_github)

    get "/activeagents/api/github_connection/connect"

    assert_redirected_to "/activeagents/settings?github=forbidden&tab=integrations"
  end

  test "a denied GitHub callback stores nothing and discards the state" do
    allowed = true
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_github || allowed }
    get "/activeagents/api/github_connection/connect"
    state = Rack::Utils.parse_query(URI.parse(response.location).query)["state"]

    allowed = false
    get "/activeagents/api/github_connection/callback", params: { code: "abc", state: state }
    assert_redirected_to "/activeagents/settings?github=forbidden&tab=integrations"
    assert_equal 0, ActionAgent::GithubConnection.count

    allowed = true
    get "/activeagents/api/github_connection/callback", params: { code: "abc", state: state }
    assert_redirected_to "/activeagents/settings?github=invalid_state&tab=integrations"
  end

  test "a checker is asked only about the action an endpoint performs" do
    deny(:manage_github)

    post "/activeagents/api/api_keys", params: { name: "unrelated" }
    assert_response :created

    post "/activeagents/api/provider_keys", params: { provider: "openai", credential: "sk-unrelated" }
    assert_response :created
  end

  test "multi-tenant: a request with no signed-in user is refused" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    ActionAgent.multi_tenant = true
    account = User.create!(email: "account-#{SecureRandom.hex(3)}@example.com", name: "Account", age: 30)
    ActionAgent.current_account_resolver = ->(_controller) { account }
    ActionAgent.current_user_resolver = ->(_controller) { nil }
    ActionAgent.permission_checker = ->(*) { true }

    post "/activeagents/api/api_keys", params: { name: "anonymous" }

    assert_forbidden(:manage_api_keys)
    assert_equal 0, ActionAgent::ApiKey.count
  end

  private

  # Denies +action+ and allows every other.
  def deny(denied)
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != denied }
  end

  def assert_forbidden(action)
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["code"]
    assert_equal action.to_s, body["permission"]
  end

  def capture_log
    output = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    yield
    output.string
  ensure
    Rails.logger = original
  end
end
