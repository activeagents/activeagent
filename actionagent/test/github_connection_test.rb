# frozen_string_literal: true

require "test_helper"

# Settings -> Integrations: connecting GitHub with OAuth, choosing the
# repositories the workspace may use, and booting a checkout sandbox whose app
# runtime serves agents its own tools over MCP (#477).
class GithubConnectionTest < ActionDispatch::IntegrationTest
  REPOS = [
    { id: 1, full_name: "acme/shop", private: true, default_branch: "main", html_url: "https://github.com/acme/shop" },
    { id: 2, full_name: "acme/docs", private: false, default_branch: "trunk", html_url: "https://github.com/acme/docs" }
  ].freeze

  def setup
    ActionAgent::GithubConnection.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent.github_client_id = "client-id"
    ActionAgent.github_client_secret = "client-secret"
  end

  def teardown
    ActionAgent.github_client_id = nil
    ActionAgent.github_client_secret = nil
  end

  test "status reports whether OAuth is configured and never renders the token" do
    connect!(repositories: [ repo_row("acme/shop") ])

    get "/activeagents/api/github_connection"

    assert_response :success
    body = JSON.parse(response.body)
    assert body["configured"]
    assert body["connected"]
    assert_equal "octocat", body.dig("connection", "login")
    assert_equal [ "acme/shop" ], body.dig("connection", "repositories").map { |r| r["full_name"] }
    assert_not_includes response.body, "gho_secret"
  end

  test "connect is refused back to Settings when no OAuth app is configured" do
    ActionAgent.github_client_id = nil
    skip "GITHUB_CLIENT_ID is set in this environment" if ENV["GITHUB_CLIENT_ID"].present?

    get "/activeagents/api/github_connection/connect"

    assert_redirected_to "/activeagents/settings?github=not_configured&tab=integrations"
  end

  test "the OAuth flow stores an encrypted connection for a single-use state" do
    get "/activeagents/api/github_connection/connect"

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "github.com", location.host
    query = Rack::Utils.parse_query(location.query)
    assert_equal "client-id", query["client_id"]
    assert_equal "http://www.example.com/activeagents/api/github_connection/callback", query["redirect_uri"]
    state = query["state"]
    assert state.present?

    stub_request(:post, GithubConnectionTest.token_url)
      .with(body: hash_including("code" => "abc", "client_secret" => "client-secret"))
      .to_return(status: 200, body: { access_token: "gho_secret", scope: "repo,read:user" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://api.github.com/user")
      .with(headers: { "Authorization" => "Bearer gho_secret" })
      .to_return(status: 200, body: { id: 42, login: "octocat", avatar_url: "https://avatars/42" }.to_json)

    get "/activeagents/api/github_connection/callback", params: { code: "abc", state: state }

    assert_redirected_to "/activeagents/settings?github=connected&tab=integrations"
    connection = ActionAgent::GithubConnection.sole
    assert_equal "octocat", connection.login
    assert_equal "gho_secret", connection.access_token
    assert_not_equal "gho_secret", raw_column(connection, :access_token), "the token must be stored encrypted"

    # The state was consumed: replaying the callback is refused.
    get "/activeagents/api/github_connection/callback", params: { code: "abc", state: state }
    assert_redirected_to "/activeagents/settings?github=invalid_state&tab=integrations"
  end

  test "a callback with a forged state is refused without calling GitHub" do
    get "/activeagents/api/github_connection/connect"
    get "/activeagents/api/github_connection/callback", params: { code: "abc", state: "forged" }

    assert_redirected_to "/activeagents/settings?github=invalid_state&tab=integrations"
    assert_equal 0, ActionAgent::GithubConnection.count
  end

  test "repositories lists what the token reaches, marked by selection" do
    connect!(repositories: [ repo_row("acme/docs") ])
    stub_repositories

    get "/activeagents/api/github_connection/repositories"

    assert_response :success
    rows = JSON.parse(response.body)["repositories"]
    assert_equal %w[acme/shop acme/docs], rows.map { |r| r["full_name"] }
    assert_equal [ false, true ], rows.map { |r| r["selected"] }
  end

  test "the selection keeps only repositories GitHub lists for the token" do
    connect!
    stub_repositories

    patch "/activeagents/api/github_connection", params: { repositories: [ "acme/shop", "evil/elsewhere" ] }, as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "evil/elsewhere"
    assert_empty ActionAgent::GithubConnection.sole.repositories

    patch "/activeagents/api/github_connection", params: { repositories: [ "ACME/Shop" ] }, as: :json
    assert_response :success
    assert_equal [ "acme/shop" ], ActionAgent::GithubConnection.sole.repository_names
  end

  test "the selection can be cleared" do
    connect!(repositories: [ repo_row("acme/shop") ])
    stub_repositories

    patch "/activeagents/api/github_connection", params: { repositories: [] }, as: :json

    assert_response :success, response.body
    assert_empty ActionAgent::GithubConnection.sole.repositories
  end

  test "a revoked token asks the owner to reconnect" do
    connect!
    stub_request(:get, %r{https://api.github.com/user/repos}).to_return(status: 401, body: "{}")

    get "/activeagents/api/github_connection/repositories"

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["reconnect_required"]
  end

  test "disconnecting removes the connection" do
    connect!

    delete "/activeagents/api/github_connection"

    assert_response :no_content
    assert_equal 0, ActionAgent::GithubConnection.count
  end

  test "an app_runtime sandbox checks out a selected repository and exposes its runtime" do
    connect!(repositories: [ repo_row("acme/docs") ])

    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/docs" }, as: :json

    assert_response :created, response.body
    sandbox = JSON.parse(response.body)["sandbox"]
    assert_equal "acme/docs", sandbox["repository"]
    assert_equal "trunk", sandbox["repository_ref"], "the default branch is used when no ref is given"
    # A checkout boots in the background; the client polls until it is ready.
    assert_equal "provisioning", sandbox["status"]
    assert_not_includes response.body, "gho_secret"

    perform_enqueued_jobs

    get "/activeagents/api/sandboxes/#{sandbox['session_id']}"
    sandbox = JSON.parse(response.body)["sandbox"]
    assert_equal "ready", sandbox["status"]
    assert_equal "sandbox:#{sandbox['session_id']}", sandbox["runtime_server_key"]
    assert_not_includes response.body, "gho_secret"

    session = ActionAgent::SandboxSession.find_by!(session_id: sandbox["session_id"])
    spec = session.checkout_spec
    assert_equal "https://github.com/acme/docs.git", spec[:clone_url]
    assert_equal "gho_secret", spec[:token]

    entry = ActionAgent::SandboxSession.runtime_server_entry(session.runtime_server_key, owner: nil)
    assert_equal "streamable_http", entry[:transport]
    assert_equal "http://127.0.0.1:8080/activeagents/mcp", entry[:url]
  end

  test "an app_runtime sandbox refuses a repository that was not selected" do
    connect!(repositories: [ repo_row("acme/docs") ])

    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/shop" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/not one of the repositories selected/, JSON.parse(response.body)["errors"].join)
  end

  test "an agent reaches a checkout runtime's tools with its bearer token" do
    connect!(repositories: [ repo_row("acme/docs") ])
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")
    session.mark_ready!(cloud_run_url: "http://runtime", runtime_mcp_url: "http://runtime.test/mcp", runtime_mcp_token: "aa_runtime")
    agent = ActionAgent::Agent.create!(name: "Checkout agent", provider: "anthropic", model: "claude-haiku-4-5",
      mcp_servers: [ session.runtime_server_key ])

    stub_request(:post, "http://runtime.test/mcp")
      .with(headers: { "Authorization" => "Bearer aa_runtime" })
      .to_return(
        { status: 200, body: { jsonrpc: "2.0", id: 1, result: {} }.to_json, headers: { "Mcp-Session-Id" => "s1" } },
        { status: 200, body: { jsonrpc: "2.0", id: 2, result: { tools: [ { name: "lookup_order", description: "Find an order" } ] } }.to_json }
      )

    definitions = ActionAgent::MCPToolDispatcher.new(agent).tool_definitions

    assert_equal [ "lookup_order" ], definitions.map { |d| d[:name] }
  end

  test "a checkout runtime is invisible to another owner's agents" do
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger@example.com", name: "Stranger", age: 30)
    session = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp", user_id: owner.id)
    session.update_columns(sandbox_type: "app_runtime", repository: "acme/docs", runtime_mcp_url: "http://runtime.test/mcp")

    assert ActionAgent::SandboxSession.runtime_server_entry(session.runtime_server_key, owner: owner)
    assert_nil ActionAgent::SandboxSession.runtime_server_entry(session.runtime_server_key, owner: stranger)
  ensure
    ActionAgent.user_class = nil
  end

  def self.token_url = "https://github.com/login/oauth/access_token"

  private

  def connect!(repositories: [])
    ActionAgent::GithubConnection.create!(
      access_token: "gho_secret", github_user_id: 42, login: "octocat", scopes: "repo,read:user",
      repositories: repositories
    )
  end

  def repo_row(full_name)
    ActionAgent::GithubClient.slice_repository(REPOS.find { |r| r[:full_name] == full_name }.deep_stringify_keys)
  end

  def stub_repositories
    stub_request(:get, %r{https://api.github.com/user/repos})
      .with(headers: { "Authorization" => "Bearer gho_secret" })
      .to_return(status: 200, body: REPOS.to_json)
  end

  def raw_column(record, column)
    connection = record.class.connection
    connection.select_value(
      "SELECT #{connection.quote_column_name(column)} FROM #{connection.quote_table_name(record.class.table_name)} " \
      "WHERE id = #{connection.quote(record.id)}"
    )
  end
end
