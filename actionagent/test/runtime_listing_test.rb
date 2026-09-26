# frozen_string_literal: true

require "test_helper"

# A checkout sandbox's app runtime, as the dashboard lists it (#489): on MCP
# Services beside the catalog, and in an agent's Tools tab as a service the
# agent can be given under its "sandbox:<session_id>" key.
#
# A runtime is listed only while it is live and only to its owner, and a
# listing never carries the bearer token its MCP endpoint expects — that goes
# to MCPToolDispatcher alone (SandboxSession#runtime_server_entry).
class RuntimeListingTest < ActionDispatch::IntegrationTest
  RUNTIME_URL = "http://127.0.0.1:4100/activeagents/mcp"
  RUNTIME_TOKEN = "aa_runtime_listing_s3cret"

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::SandboxSession.delete_all
    @previous_user_class = ActionAgent.user_class
    @previous_user_resolver = ActionAgent.current_user_resolver
    @previous_agent_scope = ActionAgent.agent_scope_resolver
  end

  def teardown
    ActionAgent.user_class = @previous_user_class
    ActionAgent.current_user_resolver = @previous_user_resolver
    ActionAgent.agent_scope_resolver = @previous_agent_scope
  end

  # A checkout sandbox as its backend leaves it once booted. Saved without
  # validation: the repository check reads the owner's GitHub selection,
  # which is covered in GithubConnectionTest and beside the point here.
  def start_runtime(repository: "acme/docs", ref: "main", user: nil, url: RUNTIME_URL, token: RUNTIME_TOKEN)
    session = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime",
      repository: repository, repository_ref: ref, user_id: user&.id
    )
    session.save!(validate: false)
    session.mark_ready!(
      cloud_run_url: "http://127.0.0.1:4100", cloud_run_job_id: "local-#{session.session_id}",
      runtime_mcp_url: url, runtime_mcp_token: token
    )
    session
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!({ name: "Checkout agent", provider: "openai", model: "gpt-4o-mini" }.merge(attributes))
  end

  def sign_in_per_user
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    ActionAgent.user_class = "User"
    ActionAgent.current_user_resolver = ->(_controller) { owner }
    [ owner, stranger ]
  end

  def servers_body
    get "/activeagents/api/mcp_servers"
    assert_response :success
    JSON.parse(response.body)
  end

  def roster_for(agent)
    get "/activeagents/api/agents/#{agent.id}/tool_roster"
    assert_response :success
    JSON.parse(response.body)
  end

  def row(rows, key)
    rows.find { |candidate| candidate["key"] == key }
  end

  # --- MCP Services ---------------------------------------------------

  test "a live runtime is listed on MCP Services with its endpoint and never its token" do
    session = start_runtime

    body = servers_body
    runtime = row(body["servers"], session.runtime_server_key)

    assert_not_nil runtime, "a live runtime should be listed beside the catalog"
    assert_equal "acme/docs@main (sandbox)", runtime["name"]
    assert_equal "streamable_http", runtime["transport"]
    assert_equal RUNTIME_URL, runtime["url"]
    assert runtime["known"]
    assert runtime["runtime"]
    assert_equal "available", runtime["status"]
    # It is already running; there is nothing to start.
    assert_equal false, runtime["launchable"]
    assert_not_includes response.body, RUNTIME_TOKEN
    assert_not_includes response.body, "Bearer"
  end

  test "a live runtime is fetchable on its own, without its token" do
    session = start_runtime

    get "/activeagents/api/mcp_servers/#{session.runtime_server_key}"

    assert_response :success
    server = JSON.parse(response.body)["server"]
    assert_equal session.runtime_server_key, server["key"]
    assert_equal "acme/docs@main (sandbox)", server["name"]
    assert_equal "streamable_http", server["transport"]
    assert_equal RUNTIME_URL, server["url"]
    assert_not_includes response.body, RUNTIME_TOKEN
  end

  test "an agent that names a runtime makes it configured" do
    session = start_runtime
    create_agent(mcp_servers: [ session.runtime_server_key ])

    runtime = row(servers_body["servers"], session.runtime_server_key)

    assert_equal "configured", runtime["status"]
    assert_equal [ "Checkout agent" ], runtime["configured_by"]
  end

  test "another owner's runtime is not listed or fetchable" do
    owner, stranger = sign_in_per_user
    mine = start_runtime(repository: "acme/docs", user: owner)
    theirs = start_runtime(repository: "rival/secret-app", user: stranger, token: "aa_theirs_s3cret")

    body = servers_body

    assert row(body["servers"], mine.runtime_server_key)
    assert_nil row(body["servers"], theirs.runtime_server_key)
    assert_not_includes response.body, "rival/secret-app"
    assert_not_includes response.body, "aa_theirs_s3cret"

    get "/activeagents/api/mcp_servers/#{theirs.runtime_server_key}"
    assert_response :not_found
  end

  test "a runtime that is not live is not listed" do
    expired = start_runtime(repository: "acme/expired")
    expired.update!(status: :expired)
    failed = start_runtime(repository: "acme/failed")
    failed.update!(status: :failed)
    lapsed = start_runtime(repository: "acme/lapsed")
    lapsed.update_columns(expires_at: 1.minute.ago)
    booting = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/booting", repository_ref: "main"
    )
    booting.save!(validate: false)
    booting.update!(status: :provisioning)

    body = servers_body
    keys = body["servers"].map { |server| server["key"] }

    [ expired, failed, lapsed, booting ].each do |session|
      assert_not_includes keys, session.runtime_server_key, "#{session.repository} (#{session.status}) should not be listed"
    end
    assert_not_includes response.body, RUNTIME_TOKEN

    get "/activeagents/api/mcp_servers/#{failed.runtime_server_key}"
    assert_response :not_found
  end

  # --- an agent's Tools tab --------------------------------------------

  test "the roster lists the agent owner's runtime as a known Streamable HTTP service" do
    session = start_runtime
    agent = create_agent

    body = roster_for(agent)
    runtime = row(body["services"], session.runtime_server_key)

    assert_not_nil runtime
    assert_equal "acme/docs@main (sandbox)", runtime["name"]
    assert runtime["known"]
    assert runtime["runtime"]
    assert_equal "Streamable HTTP · #{RUNTIME_URL}", runtime["transport"]
    assert_equal false, runtime["enabled"]
    assert_equal "available", runtime["status"]
    # The catalog is listed as before, with the runtime beside it.
    assert_equal ActionAgent::MCPCatalog.keys.size + 1, body["services"].size
    assert_not_includes response.body, RUNTIME_TOKEN
  end

  test "a runtime the agent names is enabled on its roster, whichever shape names it" do
    session = start_runtime
    by_key = create_agent(name: "By key", mcp_servers: [ session.runtime_server_key ])
    by_entry = create_agent(
      name: "By entry",
      mcp_servers: [ { "key" => session.runtime_server_key, "name" => "acme/docs@main (sandbox)" } ]
    )

    [ by_key, by_entry ].each do |agent|
      runtime = row(roster_for(agent)["services"], session.runtime_server_key)

      assert runtime["enabled"], "#{agent.name} should have the runtime on"
      assert_equal "configured", runtime["status"]
      assert_not_includes response.body, RUNTIME_TOKEN
    end
  end

  test "the roster offers only the agent owner's runtimes" do
    owner, stranger = sign_in_per_user
    mine = start_runtime(repository: "acme/docs", user: owner)
    theirs = start_runtime(repository: "rival/secret-app", user: stranger)
    agent = create_agent(user_id: owner.id)

    body = roster_for(agent)

    assert row(body["services"], mine.runtime_server_key)
    assert_nil row(body["services"], theirs.runtime_server_key)
    assert_not_includes response.body, "rival/secret-app"
  end

  # A host can let a caller reach agents it does not own (an account's
  # members sharing agents, say). The runtimes on such an agent's roster are
  # still its owner's — the only ones the dispatcher would reach for it — and
  # of those only the ones the caller may see, which here is none of them.
  test "a caller editing someone else's agent is offered neither owner's runtimes" do
    owner, stranger = sign_in_per_user
    ActionAgent.agent_scope_resolver = ->(_owner) { ActionAgent::Agent.all }
    mine = start_runtime(repository: "acme/docs", user: owner)
    theirs = start_runtime(repository: "rival/secret-app", user: stranger)
    shared = create_agent(user_id: stranger.id)

    body = roster_for(shared)

    assert_nil row(body["services"], mine.runtime_server_key), "the caller's runtime is not one this agent can reach"
    assert_nil row(body["services"], theirs.runtime_server_key), "the agent owner's runtime is not the caller's to see"
    assert_not_includes response.body, "rival/secret-app"
  end
end
