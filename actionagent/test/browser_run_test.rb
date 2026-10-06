# frozen_string_literal: true

require "test_helper"

# A run against a checkout sandbox whose browser is running reaches that
# browser as the MCP server "browser:<session_id>": each browser tool is
# offered once, from the browser, and its calls carry the browser's token.
# The runtime, the browser and the model are stubbed on the wire.
class BrowserRunTest < ActionDispatch::IntegrationTest
  RUNTIME_URL = "http://127.0.0.1:4100/activeagents/mcp"
  RUNTIME_TOKEN = "aa_runtime_browser_run_s3cret"
  BROWSER_URL = "http://127.0.0.1:4200/mcp"
  BROWSER_TOKEN = "aabrw_browserRunToken0123456789abcdefghijklmn"
  CHAT_URL = "https://api.openai.com/v1/chat/completions"
  BROWSER_TOOLS = %w[browser_navigate browser_snapshot browser_click].freeze

  def setup
    WebMock::RequestRegistry.instance.reset!
    ActionAgent::Agent.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::PlaywrightMCPClient.reset!
    @original_resolver = ActionAgent.provider_credentials_resolver
    ActionAgent.provider_credentials_resolver = lambda do |_owner, provider|
      provider == "openai" ? { access_token: "synthetic-fixture-key", api_version: :chat } : {}
    end
    @sandbox = live_sandbox
    @agent = ActionAgent::Agent.create!(
      name: "Explorer", provider: "openai", model: "gpt-4o-mini", instructions: "Look around the app.",
      mcp_servers: [], tools: [ "playwright_mcp" ]
    )
  end

  def teardown
    ActionAgent.provider_credentials_resolver = @original_resolver
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent::PlaywrightMCPClient.reset!
  end

  test "a run against a sandbox with a running browser is offered each browser tool once, and calls the browser" do
    start_browser
    stub_runtime
    stub_browser
    stub_model(call: [ "browser_navigate", { url: "/orders" } ])

    ActionAgent::PlaywrightMCPClient.stub(:instance, -> { flunk "the shared browser was used" }) do
      post "/activeagents/api/agents/#{@agent.id}/test", params: { prompt: "Open the orders page", sandbox_id: @sandbox.session_id }, as: :json
    end

    assert_response :success, response.body
    run = @agent.agent_runs.order(:id).last
    assert run.complete?, run.error_message
    assert_equal @sandbox.browser_server_key, run.browser_server_key
    assert_requested(:post, CHAT_URL, at_least_times: 1) do |request|
      names = JSON.parse(request.body)["tools"].map { |tool| tool.dig("function", "name") }
      names.sort == (BROWSER_TOOLS + [ "lookup_order" ]).sort
    end
    assert_requested(:post, BROWSER_URL, headers: { "Authorization" => "Bearer #{BROWSER_TOKEN}" }, times: 1) do |request|
      payload = JSON.parse(request.body)
      payload["method"] == "tools/call" && payload.dig("params", "name") == "browser_navigate" &&
        payload.dig("params", "arguments") == { "url" => "/orders" }
    end
    [ run.attributes.to_json, response.body ].each { |stored| assert_not_includes stored, BROWSER_TOKEN }
  end

  test "without a browser, a single-tenant run keeps the toolbox's browser tools" do
    stub_runtime
    stub_model

    post "/activeagents/api/agents/#{@agent.id}/test", params: { prompt: "Hello", sandbox_id: @sandbox.session_id }, as: :json

    assert_response :success, response.body
    assert_nil @agent.agent_runs.order(:id).last.browser_server_key
    # The toolbox's whole browser group: navigation, typing, forms and the
    # handoff to a person, which a sandbox's own browser does not offer.
    assert_requested(:post, CHAT_URL) do |request|
      names = JSON.parse(request.body)["tools"].map { |tool| tool.dig("function", "name") }
      names.sort == (ActionAgent::AgentToolbox::SHARED_BROWSER_FUNCTIONS + [ "lookup_order" ]).sort
    end
    assert_not_requested :post, BROWSER_URL
  end

  test "a queued run whose browser stopped fails before the model is called" do
    start_browser
    post "/activeagents/api/agents/#{@agent.id}/execute", params: { prompt: "Open the orders page", sandbox_id: @sandbox.session_id }, as: :json
    assert_response :accepted
    run = ActionAgent::AgentRun.find(response.parsed_body.dig("run", "id"))
    assert_equal @sandbox.browser_server_key, run.browser_server_key
    ActionAgent::SandboxBrowser.finish!(@sandbox)

    error = assert_raises(ActionAgent::MCPToolDispatcher::SandboxUnavailable) { perform_enqueued_jobs }

    assert_match(/browser of sandbox #{@sandbox.session_id} is no longer running/, error.message)
    assert run.reload.failed?
    assert_not_requested :post, CHAT_URL
  end

  test "a client cannot name a browser for its run" do
    start_browser
    post "/activeagents/api/agents/#{@agent.id}/execute", params: {
      prompt: "Hi", params: { "_sandbox_browser" => @sandbox.browser_server_key }
    }, as: :json

    assert_response :accepted
    run = ActionAgent::AgentRun.find(response.parsed_body.dig("run", "id"))
    assert_nil run.browser_server_key
    assert_not_includes run.input_params.to_json, @sandbox.browser_server_key
  end

  test "a browser key resolves only among the agent's owner's sessions, and only as a run's own" do
    start_browser
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @sandbox.update_columns(user_id: owner.id)
    @agent.update_columns(user_id: stranger.id)

    dispatcher = ActionAgent::MCPToolDispatcher.new(@agent.reload, extra_server_keys: [ @sandbox.browser_server_key ])
    assert dispatcher.browser_attached?
    assert_raises(ActionAgent::MCPToolDispatcher::SandboxUnavailable) { dispatcher.tool_definitions }

    @agent.update_columns(user_id: owner.id, mcp_servers: [ @sandbox.browser_server_key ])
    declared = ActionAgent::MCPToolDispatcher.new(@agent.reload)
    assert_not declared.any_reachable_server?, "an agent's saved servers never reach a browser"
    assert_nil declared.call("browser_navigate", url: "/")
  end

  test "a multi-tenant install neither offers nor calls the shared browser's tools" do
    ActionAgent.multi_tenant = true

    assert_empty ActionAgent::AgentToolbox.definitions_for([ "playwright_mcp" ])
    result = ActionAgent::AgentToolbox.call("browser_navigate", url: "https://example.com")
    assert_match(/needs a browser: start the browser of the sandbox/, result[:error])
    assert_raises(ActionAgent::PlaywrightMCPClient::Error) { ActionAgent::PlaywrightMCPClient.instance }
    assert_nil ActionAgent::PlaywrightMCPClient.instance_variable_get(:@instance)
  end

  test "an evaluation's tool roster names each browser tool once" do
    start_browser
    stub_runtime
    stub_browser
    evaluation = @agent.evaluations.new(name: "Explore", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "open_orders", prompt: "Open the orders page", expectations: { "tools" => [ "browser_navigate" ] })
    evaluation.save!

    runner = ActionAgent::ScenarioEvaluationRunner.new(evaluation, selection: { sandbox_id: @sandbox.session_id })
    roster = runner.send(:tool_roster)

    assert_equal (BROWSER_TOOLS + [ "lookup_order" ]).sort, roster.keys.sort
    assert_equal "browser_navigate from the sandbox's browser", roster["browser_navigate"]
  end

  private

  def live_sandbox
    sandbox = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/shop", repository_ref: "main"
    )
    sandbox.save!(validate: false)
    sandbox.mark_ready!(cloud_run_url: "http://127.0.0.1:4100", runtime_mcp_url: RUNTIME_URL, runtime_mcp_token: RUNTIME_TOKEN)
    sandbox
  end

  def start_browser
    @sandbox.update!(browser_status: "running", browser_mode: "headless", browser_mcp_url: BROWSER_URL,
      browser_token: BROWSER_TOKEN, browser_started_at: Time.current)
  end

  def stub_mcp(url, token, tools, &call)
    stub_request(:post, url).with(headers: { "Authorization" => "Bearer #{token}" }).to_return do |request|
      payload = JSON.parse(request.body)
      result =
        case payload["method"]
        when "initialize" then { protocolVersion: "2025-03-26", capabilities: { tools: {} } }
        when "tools/list" then { tools: tools }
        when "tools/call" then { content: [ { type: "text", text: call.call(payload["params"]) } ] }
        end

      if payload.key?("id")
        { status: 200, body: { jsonrpc: "2.0", id: payload["id"], result: result }.to_json,
          headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "session-#{url.hash}" } }
      else
        { status: 202, body: "" }
      end
    end
  end

  def stub_runtime
    stub_mcp(RUNTIME_URL, RUNTIME_TOKEN, [ { name: "lookup_order", description: "Find an order by id.", inputSchema: { type: "object" } } ]) do
      "order shipped"
    end
  end

  def stub_browser
    tools = BROWSER_TOOLS.map { |name| { name: name, description: "#{name} from the sandbox's browser", inputSchema: { type: "object" } } }
    stub_mcp(BROWSER_URL, BROWSER_TOKEN, tools) { |params| "### Page\n- Page URL: http://127.0.0.1:4100#{params.dig('arguments', 'url')}" }
  end

  # The model: makes +call+ (a tool name and its arguments) first when
  # given, then answers.
  def stub_model(call: nil)
    stub_request(:post, CHAT_URL).to_return do |request|
      messages = JSON.parse(request.body)["messages"]
      message =
        if call.nil? || messages.any? { |entry| entry["role"] == "tool" }
          { role: "assistant", content: "Done." }
        else
          { role: "assistant", content: nil, tool_calls: [
            { id: "call_1", type: "function", function: { name: call.first, arguments: call.last.to_json } }
          ] }
        end

      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "chat_fixture", object: "chat.completion", created: 1, model: "gpt-4o-mini",
        choices: [ { index: 0, message: message, finish_reason: message[:tool_calls] ? "tool_calls" : "stop" } ],
        usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
      }.to_json }
    end
  end
end
