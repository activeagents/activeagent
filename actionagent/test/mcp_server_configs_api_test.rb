# frozen_string_literal: true

require "test_helper"

# The MCP Services page's own servers in a multi-tenant install: each tenant
# reads and changes only its own, header values never come back, and an
# agent's Tools tab offers the tenant's servers beside the catalog.
class MCPServerConfigsApiTest < ActionDispatch::IntegrationTest
  URL = "https://app.example.com/mcp"
  TOKEN = "Bearer acme-orders-token-0001"

  setup do
    ActionAgent::MCPServerConfig.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true

    @account = user("Acme")
    @other_account = user("Globex")
    @signed_in = user("Ada")
    @current_account = @account
    ActionAgent.current_account_resolver = ->(_controller) { @current_account }
    ActionAgent.current_user_resolver = ->(_controller) { @signed_in }

    @config = ActionAgent::MCPServerConfig.create!(
      name: "Orders", url: URL, headers: { "Authorization" => TOKEN }, account_id: @account.id, tool_names: %w[find_order]
    )
    @foreign = ActionAgent::MCPServerConfig.create!(
      name: "Billing", url: "https://billing.example.com/mcp", headers: { "X-Api-Key" => "globex-billing-key-0002" },
      account_id: @other_account.id
    )
  end

  teardown do
    ActionAgent::MCPHostGuard.resolver = nil
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.permission_checker = nil
  end

  test "the index lists the caller's servers only, with masked header values" do
    get "/activeagents/api/mcp_server_configs"

    assert_response :success
    rows = response.parsed_body["mcp_server_configs"]
    assert_equal [ "custom:#{@config.id}" ], rows.map { |row| row["key"] }
    assert_equal [ { "name" => "Authorization", "hint" => "••••0001" } ], rows.first["headers"]
    assert_equal %w[find_order], rows.first["tools"]
    assert_not_includes response.body, TOKEN
    assert_not_includes response.body, "Billing"
    assert_equal false, response.parsed_body["allow_private_hosts"]
  end

  test "create assigns the caller's owner and never echoes a header value" do
    post "/activeagents/api/mcp_server_configs", params: { mcp_server_config: {
      name: "Inventory", url: "https://inventory.example.com/mcp",
      headers: [ { name: "Authorization", value: "Bearer inventory-token-0003" } ]
    } }, as: :json

    assert_response :created
    created = ActionAgent::MCPServerConfig.find(response.parsed_body.dig("mcp_server_config", "id"))
    assert_equal @account.id, created.account_id
    assert_equal({ "Authorization" => "Bearer inventory-token-0003" }, created.headers)
    assert_not_includes response.body, "inventory-token"
  end

  test "create refuses a private address and a non-http URL" do
    post "/activeagents/api/mcp_server_configs",
      params: { mcp_server_config: { name: "Metadata", url: "http://169.254.169.254/latest" } }, as: :json
    assert_response :unprocessable_entity

    post "/activeagents/api/mcp_server_configs",
      params: { mcp_server_config: { name: "File", url: "file:///etc/passwd" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal 2, ActionAgent::MCPServerConfig.count
  end

  test "update keeps a header left blank, removes one left out, and forgets the old URL's test" do
    @config.update!(headers: { "Authorization" => TOKEN, "X-Tenant" => "acme" }, last_test_status: "ok")

    patch "/activeagents/api/mcp_server_configs/#{@config.id}", params: { mcp_server_config: {
      url: "https://orders.example.com/mcp", headers: [ { name: "Authorization", value: "" } ]
    } }, as: :json

    assert_response :success
    @config.reload
    assert_equal({ "Authorization" => TOKEN }, @config.headers)
    assert_nil @config.last_test_status
    assert_empty @config.tool_names_list

    patch "/activeagents/api/mcp_server_configs/#{@config.id}", params: { mcp_server_config: { enabled: false } }, as: :json
    assert_equal({ "Authorization" => TOKEN }, @config.reload.headers, "omitting headers keeps them all")
    assert_not @config.enabled?
  end

  test "another tenant's server cannot be read, changed, tested or deleted" do
    patch "/activeagents/api/mcp_server_configs/#{@foreign.id}", params: { mcp_server_config: { name: "Mine now" } }, as: :json
    assert_response :not_found
    post "/activeagents/api/mcp_server_configs/#{@foreign.id}/test"
    assert_response :not_found
    delete "/activeagents/api/mcp_server_configs/#{@foreign.id}"
    assert_response :not_found

    assert_equal "Billing", @foreign.reload.name
  end

  test "a caller without a resolved tenant is refused" do
    @current_account = nil

    get "/activeagents/api/mcp_server_configs"

    assert_response :unauthorized
  end

  test "writes and tests ask :manage_credentials" do
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_credentials }

    post "/activeagents/api/mcp_server_configs", params: { mcp_server_config: { name: "X", url: URL } }, as: :json
    assert_response :forbidden
    delete "/activeagents/api/mcp_server_configs/#{@config.id}"
    assert_response :forbidden
    post "/activeagents/api/mcp_server_configs/#{@config.id}/test"
    assert_response :forbidden
    get "/activeagents/api/mcp_server_configs"
    assert_equal false, response.parsed_body["can_manage"]
    assert ActionAgent::MCPServerConfig.exists?(@config.id)
  end

  test "test runs tools/list with the stored headers and records the tools" do
    ActionAgent::MCPHostGuard.resolver = ->(_host) { %w[93.184.216.34] }
    stub_request(:post, URL).with(headers: { "Authorization" => TOKEN }).to_return do |request|
      payload = JSON.parse(request.body)
      result = payload["method"] == "tools/list" ? { tools: [ { name: "find_order" }, { name: "cancel_order" } ] } : {}
      payload.key?("id") ? { status: 200, body: { jsonrpc: "2.0", id: payload["id"], result: result }.to_json } : { status: 202, body: "" }
    end

    post "/activeagents/api/mcp_server_configs/#{@config.id}/test"

    assert_response :success
    assert_equal true, response.parsed_body["ok"]
    assert_equal %w[find_order cancel_order], response.parsed_body["tools"]
    assert_equal %w[find_order cancel_order], @config.reload.tool_names_list
    assert_equal "ok", @config.last_test_status
    assert_not_includes response.body, TOKEN
  end

  test "a test against a host that resolves privately fails without a request" do
    ActionAgent::MCPHostGuard.resolver = ->(_host) { %w[10.0.0.7] }
    stub = stub_request(:post, URL)

    post "/activeagents/api/mcp_server_configs/#{@config.id}/test"

    assert_response :success
    assert_equal false, response.parsed_body["ok"]
    assert_match(/private, loopback or link-local/, response.parsed_body["error"])
    assert_equal "failed", @config.reload.last_test_status
    assert_not_requested stub
  end

  private

  def user(name)
    User.create!(name: name, email: "#{name.downcase}-#{SecureRandom.hex(3)}@example.com", age: 30)
  end
end

# The same servers on an agent's Tools tab and the MCP Services page, in an
# install that owns everything per user: the owner's servers are offered
# beside the catalog, never another user's.
class MCPServerConfigsRosterTest < ActionDispatch::IntegrationTest
  TOKEN = MCPServerConfigsApiTest::TOKEN

  setup do
    ActionAgent::MCPServerConfig.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent.user_class = "User"
    @owner = User.create!(name: "Owner", email: "owner-#{SecureRandom.hex(3)}@example.com", age: 30)
    @stranger = User.create!(name: "Stranger", email: "stranger-#{SecureRandom.hex(3)}@example.com", age: 30)
    ActionAgent.current_user_resolver = ->(_controller) { @owner }

    @config = ActionAgent::MCPServerConfig.create!(
      name: "Orders", url: MCPServerConfigsApiTest::URL, headers: { "Authorization" => TOKEN },
      user_id: @owner.id, tool_names: %w[find_order]
    )
    @foreign = ActionAgent::MCPServerConfig.create!(
      name: "Billing", url: "https://billing.example.com/mcp", user_id: @stranger.id
    )
  end

  teardown do
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
  end

  test "an agent's Tools tab and the MCP Services page list the tenant's servers, never another's" do
    agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini",
                                       user_id: @owner.id, mcp_servers: [ "custom:#{@config.id}" ])

    get "/activeagents/api/agents/#{agent.id}/tool_roster"
    assert_response :success
    services = response.parsed_body["services"].index_by { |service| service["key"] }
    row = services.fetch("custom:#{@config.id}")
    assert_equal "Orders", row["name"]
    assert_equal true, row["enabled"]
    assert_equal true, row["custom"]
    assert_equal true, row["callable"]
    assert_equal %w[find_order], row["tools"].map { |tool| tool["name"] }
    assert_not services.key?("custom:#{@foreign.id}")
    assert_not_includes response.body, TOKEN

    get "/activeagents/api/agents/tool_roster"
    assert response.parsed_body["services"].any? { |service| service["key"] == "custom:#{@config.id}" }

    get "/activeagents/api/mcp_servers"
    keys = response.parsed_body["servers"].map { |server| server["key"] }
    assert_includes keys, "custom:#{@config.id}"
    assert_not_includes keys, "custom:#{@foreign.id}"
    assert_not_includes response.body, TOKEN
  end

  test "a disabled server is listed on the Tools tab as not callable" do
    @config.update!(enabled: false)
    agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini", user_id: @owner.id)

    get "/activeagents/api/agents/#{agent.id}/tool_roster"

    row = response.parsed_body["services"].find { |service| service["key"] == "custom:#{@config.id}" }
    assert_equal false, row["callable"]
    assert_match(/Switched off/, row["unavailable_reason"])
  end
end
