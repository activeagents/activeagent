# frozen_string_literal: true

require "test_helper"
require_relative "support/github_app"

# Settings -> Integrations: installing the GitHub App, linking an
# installation only for a user who administers its account, choosing its
# repositories, and unlinking it.
class GithubInstallationsTest < ActionDispatch::IntegrationTest
  include GithubAppTestHelper

  CALLBACK = "/activeagents/api/github_installations/callback"

  def setup
    ActionAgent::GithubInstallation.delete_all
    ActionAgent::GithubConnection.delete_all
    configure_github_app!
  end

  def teardown
    reset_github_app!
    ActionAgent.permission_checker = nil
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
  end

  test "with no App configured the connection reports none and the install flow is refused" do
    link_installation!
    reset_github_app!
    skip "GITHUB_APP_* is set in this environment" if ActionAgent.github_app_configured?

    get "/activeagents/api/github_connection"
    app = JSON.parse(response.body)["app"]
    assert_equal false, app["configured"]
    assert_nil app["slug"]
    assert_empty app["installations"]

    get "/activeagents/api/github_installations/install"
    assert_redirected_to "/activeagents/settings?github_app=not_configured&tab=integrations"

    get "/activeagents/api/github_installations/1/repositories"
    assert_response :not_found
    assert_equal "github_app_not_configured", JSON.parse(response.body)["code"]
  end

  test "install sends the admin to the App's installation page with a fresh state" do
    get "/activeagents/api/github_installations/install"

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "github.com", location.host
    assert_equal "/apps/#{SLUG}/installations/new", location.path
    assert Rack::Utils.parse_query(location.query)["state"].present?
  end

  test "a user installation is linked for the user it is installed on, and the user token is kept nowhere" do
    state = start_install
    stub_app_user(installations: [ github_installation ])

    logged = capture_log do
      get CALLBACK, params: { installation_id: INSTALLATION_ID, setup_action: "install", code: "app-code", state: state }
    end

    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"
    installation = ActionAgent::GithubInstallation.sole
    assert_equal INSTALLATION_ID, installation.installation_id
    assert_equal GITHUB_USER_ID, installation.github_account_id
    assert_equal "octocat", installation.github_account_login
    assert_equal "User", installation.github_account_type
    assert_equal "selected", installation.repository_selection
    assert_equal "write", installation.permissions["contents"]
    assert_empty installation.repositories, "nothing is selected until the owner chooses"

    assert_includes logged, "GithubInstallationsController#callback", "the request log was captured"
    assert_not_includes logged, USER_TOKEN
    assert_not_includes logged, "ghr_"
    assert_not_includes installation.attributes.values.map(&:to_s).join("\n"), USER_TOKEN
    assert_not_includes session.to_hash.to_s, USER_TOKEN
  end

  test "an organization installation is linked for an active admin of that organization" do
    state = start_install
    stub_app_user(installations: [ github_installation(account_type: "Organization", account_id: 555, login: "acme") ])
    stub_membership("acme", state: "active", role: "admin")

    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"
    assert_equal "acme", ActionAgent::GithubInstallation.sole.github_account_login
  end

  test "an organization installation is refused for a member who is not an active admin" do
    [ { state: "active", role: "member" }, { state: "pending", role: "admin" }, { status: 404 } ].each do |membership|
      state = start_install
      stub_app_user(installations: [ github_installation(account_type: "Organization", account_id: 555, login: "acme") ])
      stub_membership("acme", **membership)

      get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }

      assert_redirected_to "/activeagents/settings?github_app=not_admin&tab=integrations", membership.inspect
      assert_equal 0, ActionAgent::GithubInstallation.count
    end
  end

  test "a user installation on another GitHub account is refused" do
    state = start_install
    stub_app_user(installations: [ github_installation(account_type: "User", account_id: GITHUB_USER_ID + 1, login: "someone") ])

    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=not_admin&tab=integrations"
    assert_equal 0, ActionAgent::GithubInstallation.count
  end

  test "an installation the user cannot reach is refused whatever the URL claims" do
    state = start_install
    stub_app_user(installations: [ github_installation(id: INSTALLATION_ID + 1) ])

    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=not_found&tab=integrations"
    assert_equal 0, ActionAgent::GithubInstallation.count
  end

  test "a mismatched state is refused without exchanging the code" do
    exchange = stub_request(:post, "https://github.com/login/oauth/access_token")
    start_install

    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: "forged" }

    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations"
    assert_not_requested exchange
    assert_equal 0, ActionAgent::GithubInstallation.count
  end

  test "a state is single use" do
    state = start_install
    stub_app_user(installations: [ github_installation ])
    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }
    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"
    ActionAgent::GithubInstallation.delete_all
    WebMock.reset!
    exchange = stub_request(:post, "https://github.com/login/oauth/access_token")

    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations"
    assert_not_requested exchange
    assert_equal 0, ActionAgent::GithubInstallation.count
  end

  test "a callback with a state but none issued in this session is refused" do
    exchange = stub_request(:post, "https://github.com/login/oauth/access_token")

    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: "never-issued" }

    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations"
    assert_not_requested exchange
  end

  test "a state issued to another signed-in user is refused" do
    ActionAgent.user_class = "User"
    first = User.create!(email: "first@example.com", name: "First", age: 30)
    second = User.create!(email: "second@example.com", name: "Second", age: 30)
    signed_in = first
    ActionAgent.current_user_resolver = ->(_controller) { signed_in }
    state = start_install

    signed_in = second
    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations"
    assert_equal 0, ActionAgent::GithubInstallation.count
  end

  test "an install started on GitHub goes through the App's user authorization before anything is linked" do
    exchange = stub_request(:post, "https://github.com/login/oauth/access_token")

    get CALLBACK, params: { installation_id: INSTALLATION_ID, setup_action: "install", code: "unsolicited" }

    assert_not_requested exchange
    assert_equal 0, ActionAgent::GithubInstallation.count
    location = URI.parse(response.location)
    assert_equal "/login/oauth/authorize", location.path
    query = Rack::Utils.parse_query(location.query)
    assert_equal CLIENT_ID, query["client_id"]
    assert_equal "http://www.example.com#{CALLBACK}", query["redirect_uri"]
    assert_nil query["scope"], "a GitHub App's permissions are set on the App"

    stub_app_user(installations: [ github_installation ])
    get CALLBACK, params: { code: "app-code", state: query["state"] }

    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"
    assert_equal INSTALLATION_ID, ActionAgent::GithubInstallation.sole.installation_id
  end

  test "a request to an organization owner links nothing and reports it pending" do
    state = start_install

    get CALLBACK, params: { setup_action: "request", code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=pending&tab=integrations"
    assert_equal 0, ActionAgent::GithubInstallation.count
  end

  test "an installation linked to another owner is refused, and one owner may link several" do
    ActionAgent.user_class = "User"
    other = User.create!(email: "other@example.com", name: "Other", age: 30)
    owner = User.create!(email: "owner@example.com", name: "Owner", age: 30)
    ActionAgent.current_user_resolver = ->(_controller) { owner }
    link_installation!(installation_id: INSTALLATION_ID, user_id: other.id)

    state = start_install
    stub_app_user(installations: [ github_installation ])
    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }
    assert_redirected_to "/activeagents/settings?github_app=taken&tab=integrations"
    assert_equal other.id, ActionAgent::GithubInstallation.sole.user_id

    state = start_install
    stub_app_user(installations: [ github_installation(id: INSTALLATION_ID + 1) ])
    get CALLBACK, params: { installation_id: INSTALLATION_ID + 1, code: "app-code", state: state }
    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"

    state = start_install
    stub_app_user(installations: [ github_installation(id: INSTALLATION_ID + 2, account_type: "Organization", account_id: 555, login: "acme") ])
    stub_membership("acme")
    get CALLBACK, params: { installation_id: INSTALLATION_ID + 2, code: "app-code", state: state }
    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"

    assert_equal [ INSTALLATION_ID + 1, INSTALLATION_ID + 2 ],
      ActionAgent::GithubInstallation.where(user_id: owner.id).order(:installation_id).pluck(:installation_id)
  end

  test "relinking an owner's own installation updates its row and clears a recorded removal" do
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ], removed_at: 1.day.ago)
    state = start_install
    stub_app_user(installations: [ github_installation(account_type: "Organization", account_id: 555, login: "acme-renamed") ])
    stub_membership("acme-renamed")

    get CALLBACK, params: { installation_id: INSTALLATION_ID, setup_action: "update", code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"
    installation.reload
    assert_equal 1, ActionAgent::GithubInstallation.count
    assert_equal "acme-renamed", installation.github_account_login
    assert_nil installation.removed_at
    assert_equal [ "acme/shop" ], installation.repository_names
  end

  test "the database refuses a second row for one installation" do
    link_installation!

    assert_raises(ActiveRecord::RecordNotUnique) do
      ActionAgent::GithubInstallation.new(
        installation_id: INSTALLATION_ID, github_account_id: 1, github_account_login: "x", github_account_type: "User"
      ).save!(validate: false)
    end
  end

  test "the connection and the index list the owner's installations without any credential" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])

    get "/activeagents/api/github_connection"
    app = JSON.parse(response.body)["app"]
    assert app["configured"]
    assert_equal SLUG, app["slug"]
    assert_equal "http://www.example.com#{CALLBACK}", app["callback_url"]
    assert app["manifest_available"]
    assert_equal [ "acme" ], app["installations"].map { |row| row["account_login"] }
    assert_equal "active", app["installations"].first["status"]

    get "/activeagents/api/github_installations"
    rows = JSON.parse(response.body)["installations"]
    assert_equal [ [ "acme/shop" ] ], rows.map { |row| row["repositories"].map { |repo| repo["full_name"] } }
  end

  test "an installation's repositories are listed with a token that only reads metadata" do
    installation = link_installation!(repositories: [ repo_row(6, "acme/docs") ])
    stub_mint(token: "ghs_listing")
    stub_installation_repositories([ repo_payload(5, "acme/shop"), repo_payload(6, "acme/docs") ], token: "ghs_listing")

    get "/activeagents/api/github_installations/#{installation.id}/repositories"

    assert_response :success
    rows = JSON.parse(response.body)["repositories"]
    assert_equal [ [ "acme/shop", false ], [ "acme/docs", true ] ], rows.map { |row| [ row["full_name"], row["selected"] ] }
    assert_requested(:post, mint_url, times: 1) { |request| JSON.parse(request.body) == { "permissions" => { "metadata" => "read" } } }
    assert_not_includes response.body, "ghs_listing"
  end

  test "the selection keeps only repositories GitHub lists for the installation" do
    installation = link_installation!
    stub_mint(token: "ghs_listing")
    stub_installation_repositories([ repo_payload(5, "acme/shop") ], token: "ghs_listing")

    patch "/activeagents/api/github_installations/#{installation.id}", params: { repositories: [ "acme/shop", "evil/elsewhere" ] }, as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "evil/elsewhere"
    assert_empty installation.reload.repositories

    patch "/activeagents/api/github_installations/#{installation.id}", params: { repositories: [ "ACME/Shop" ] }, as: :json
    assert_response :success
    assert_equal [ "acme/shop" ], installation.reload.repository_names
    assert_equal 5, installation.repository("acme/shop")["id"]
  end

  test "listing a removed installation marks it and asks for a reinstall" do
    installation = link_installation!
    stub_mint(status: 404, message: "Not Found")

    get "/activeagents/api/github_installations/#{installation.id}/repositories"

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body["reinstall_required"]
    assert_equal "removed", body.dig("installation", "status")
    assert installation.reload.removed_at
  end

  test "unlinking removes the row and only the row" do
    installation = link_installation!

    delete "/activeagents/api/github_installations/#{installation.id}"

    assert_response :no_content
    assert_equal 0, ActionAgent::GithubInstallation.count
    assert_not_requested :any, /github/
  end

  test "another owner's installation cannot be read, changed or unlinked" do
    ActionAgent.user_class = "User"
    other = User.create!(email: "other@example.com", name: "Other", age: 30)
    owner = User.create!(email: "owner@example.com", name: "Owner", age: 30)
    ActionAgent.current_user_resolver = ->(_controller) { owner }
    theirs = link_installation!(user_id: other.id)

    get "/activeagents/api/github_installations/#{theirs.id}/repositories"
    assert_response :not_found
    patch "/activeagents/api/github_installations/#{theirs.id}", params: { repositories: [] }, as: :json
    assert_response :not_found
    delete "/activeagents/api/github_installations/#{theirs.id}"
    assert_response :not_found

    get "/activeagents/api/github_installations"
    assert_empty JSON.parse(response.body)["installations"]
    assert ActionAgent::GithubInstallation.exists?(theirs.id)
  end

  test "install, callback, listing, selection and unlink answer a denied manage_github" do
    installation = link_installation!
    mint = stub_mint
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_github }

    get "/activeagents/api/github_installations/install"
    assert_redirected_to "/activeagents/settings?github_app=forbidden&tab=integrations"

    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: "any" }
    assert_redirected_to "/activeagents/settings?github_app=forbidden&tab=integrations"

    get "/activeagents/api/github_installations/#{installation.id}/repositories"
    assert_forbidden
    assert_not_requested mint

    patch "/activeagents/api/github_installations/#{installation.id}", params: { repositories: [] }, as: :json
    assert_forbidden

    delete "/activeagents/api/github_installations/#{installation.id}"
    assert_forbidden
    assert ActionAgent::GithubInstallation.exists?(installation.id)
  end

  test "a callback denied after install stores nothing and discards the state" do
    allowed = true
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_github || allowed }
    state = start_install
    stub_app_user(installations: [ github_installation ])

    allowed = false
    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }
    assert_redirected_to "/activeagents/settings?github_app=forbidden&tab=integrations"

    allowed = true
    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }
    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations"
    assert_equal 0, ActionAgent::GithubInstallation.count
  end

  test "multi-tenant: a checker that raises or answers nil denies the install" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    ActionAgent.multi_tenant = true
    account = User.create!(email: "account@example.com", name: "Account", age: 30)
    ActionAgent.current_account_resolver = ->(_controller) { account }
    ActionAgent.current_user_resolver = ->(_controller) { account }

    [ ->(*) { raise "policy service unavailable" }, ->(*) { nil } ].each do |checker|
      ActionAgent.permission_checker = checker
      get "/activeagents/api/github_installations/install"
      assert_redirected_to "/activeagents/settings?github_app=forbidden&tab=integrations"
    end

    ActionAgent.permission_checker = ->(*) { true }
    get "/activeagents/api/github_installations/install"
    assert_equal "github.com", URI.parse(response.location).host
  end

  test "multi-tenant: an installation is linked to the account and records the linking user" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    ActionAgent.multi_tenant = true
    account = User.create!(email: "account@example.com", name: "Account", age: 30)
    member = User.create!(email: "member@example.com", name: "Member", age: 30)
    ActionAgent.current_account_resolver = ->(_controller) { account }
    ActionAgent.current_user_resolver = ->(_controller) { member }
    ActionAgent.permission_checker = ->(*) { true }

    state = start_install
    stub_app_user(installations: [ github_installation ])
    get CALLBACK, params: { installation_id: INSTALLATION_ID, code: "app-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=linked&tab=integrations"
    installation = ActionAgent::GithubInstallation.sole
    assert_equal account.id, installation.account_id
    assert_equal member.id, installation.user_id
  end

  private

  def start_install
    get "/activeagents/api/github_installations/install"
    Rack::Utils.parse_query(URI.parse(response.location).query)["state"]
  end

  def assert_forbidden
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_equal "forbidden", body["code"]
    assert_equal "manage_github", body["permission"]
  end

  # Everything logged while the block runs: the request log, SQL and the
  # engine's own lines.
  def capture_log
    output = StringIO.new
    sink = ActiveSupport::Logger.new(output)
    sink.level = Logger::DEBUG
    Rails.logger.broadcast_to(sink)
    yield
    output.string
  ensure
    Rails.logger.stop_broadcasting_to(sink)
  end
end
