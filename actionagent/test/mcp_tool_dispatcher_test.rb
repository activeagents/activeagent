# frozen_string_literal: true

require "test_helper"

# Routing a tool call to the MCP server that serves it (#419): an agent names
# its servers, the host registers where they live, and the dashboard calls
# them instead of falling through to its own toolbox.
class MCPToolDispatcherTest < ActiveSupport::TestCase
  setup do
    @catalog = ActionAgent.mcp_catalog
    ActionAgent.mcp_catalog = [
      { key: "records", name: "Records", description: "Record lookups.",
        transport: "http", url: "https://host.example/mcp/records",
        tool_hints: %w[count_records find_records] },
      { key: "local", name: "Local", description: "A stdio server.",
        transport: "stdio", command: "npx local-mcp", tool_hints: %w[read_file] }
    ]
  end

  teardown { ActionAgent.mcp_catalog = @catalog }

  def agent_with(servers, tools: [])
    ActionAgent::Agent.new(name: "Probe", status: :draft, provider: "openai",
                           model: "gpt-4o-mini", mcp_servers: servers, tools: tools)
  end

  test "a tool an agent's http server serves is dispatchable" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[records]))

    assert dispatcher.dispatchable?("count_records")
  end

  test "a tool from a server the agent does not declare is left to the toolbox" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with([]))

    assert_not dispatcher.dispatchable?("count_records")
    assert_nil dispatcher.call("count_records")
  end

  test "a stdio server is not dispatchable — the dashboard has no address to call" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[local]))

    assert_not dispatcher.dispatchable?("read_file")
  end

  # VCR hooks into webmock and refuses any request without a cassette, so these
  # tests substitute the client rather than stub HTTP. The dispatcher memoizes
  # its clients per server key, so seeding that hash injects the double.

  # Stands in for MCPClient, answering the two calls the dispatcher makes.
  class StubClient
    def initialize(tools: [], raises: nil)
      @tools = tools
      @raises = raises
    end

    def list_tools
      raise ActionAgent::MCPClient::Error, @raises if @raises

      @tools
    end

    def call_tool(name, _arguments)
      raise ActionAgent::MCPClient::Error, @raises if @raises

      { "content" => [ { "type" => "text", "text" => "called #{name}" } ] }
    end
  end

  def dispatcher_with_client(client, servers: %w[records])
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(servers))
    dispatcher.instance_variable_get(:@clients)["records"] = client
    dispatcher
  end

  test "an unreachable server returns a scoreable error rather than raising" do
    dispatcher = dispatcher_with_client(StubClient.new(raises: "boom"))

    result = dispatcher.call("count_records", { "model" => "Provider" })

    assert_match(/count_records failed: boom/, result[:error])
  end

  test "a server's own tools/list becomes the schemas the model is offered" do
    tools = [ { name: "count_records", description: "Counts rows.", parameters: { type: "object" } } ]
    dispatcher = dispatcher_with_client(StubClient.new(tools: tools))

    assert_equal %w[count_records], dispatcher.tool_definitions.map { |tool| tool[:name] }
  end

  test "a server whose tools/list fails contributes no schemas" do
    dispatcher = dispatcher_with_client(StubClient.new(raises: "unreachable"))

    assert_empty dispatcher.tool_definitions
  end

  # #425: contributing nothing keeps the run alive, but a silent [] is
  # indistinguishable from a server that serves no tools. The agent then runs
  # tool-less and the model fabricates, while the run reports a plausible score.
  test "a failed tools/list records why, naming the server and its url" do
    dispatcher = dispatcher_with_client(StubClient.new(raises: "401 Unauthorized"))
    dispatcher.tool_definitions

    assert_equal %w[records], dispatcher.discovery_errors.keys
    error = dispatcher.discovery_errors["records"]
    assert_includes error, "records"
    assert_includes error, "https://host.example/mcp/records"
    assert_includes error, "401 Unauthorized"
  end

  test "a server that answers records no discovery error" do
    dispatcher = dispatcher_with_client(StubClient.new)
    dispatcher.tool_definitions

    assert_empty dispatcher.discovery_errors
    assert_not dispatcher.all_servers_failed?
  end

  test "every declared server failing is distinguishable from having no tools" do
    dispatcher = dispatcher_with_client(StubClient.new(raises: "unreachable"))
    dispatcher.tool_definitions

    assert dispatcher.all_servers_failed?
  end

  # An agent naming no server has nothing to fail: its tool-less execution is
  # the configured behaviour, not a transport problem.
  test "an agent with no declared servers has not failed discovery" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with([]))
    dispatcher.tool_definitions

    assert_empty dispatcher.discovery_errors
    assert_not dispatcher.all_servers_failed?
  end

  test "discovery errors from an earlier call do not leak into a later one" do
    dispatcher = dispatcher_with_client(StubClient.new(raises: "unreachable"))
    dispatcher.tool_definitions
    assert dispatcher.all_servers_failed?

    dispatcher.instance_variable_get(:@clients)["records"] = StubClient.new
    dispatcher.tool_definitions

    assert_empty dispatcher.discovery_errors
    assert_not dispatcher.all_servers_failed?
  end

  # A stateless server answers the initialize handshake with no Mcp-Session-Id,
  # and its notification body is a bare `null` — which JSON.parse returns as nil
  # rather than a hash.
  test "a bare null notification body parses as an empty hash" do
    client = ActionAgent::MCPClient.new(url: "https://host.example/mcp/records")
    response = Struct.new(:body) do
      def [](_header) = "application/json"
    end.new("null")

    assert_equal({}, client.send(:parse_body, response))
  end

  test "an https endpoint is requested over TLS, not plaintext on port 443" do
    client = ActionAgent::MCPClient.new(url: "https://host.example/mcp/records")

    assert_equal "https", client.instance_variable_get(:@uri).scheme
    assert_equal 443, client.instance_variable_get(:@uri).port
  end

  # --- a server entry that lists no tools --------------------------------

  # Answers the way MCPClient does, and records what it was asked to call.
  class RecordingClient
    attr_reader :calls

    def initialize(tools)
      @tools = tools
      @calls = []
    end

    def list_tools = @tools

    def call_tool(name, arguments)
      @calls << [ name, arguments ]
      { text: "#{name} answered", is_error: false }
    end
  end

  # The resolver maps a bare tool name to a server by a namespace, a catalog
  # hint or an allow-list on the agent's entry. An entry naming none of those
  # ({key, name}, as the Tools tab saves a service offering everything) used to
  # have its tools offered and then never dispatched: the model called one and
  # it fell through to the toolbox.
  test "a tool a server listed is dispatched there even when nothing else names its server" do
    ActionAgent.mcp_catalog = [
      { key: "booking", name: "Booking", transport: "http", url: "https://booking.example/mcp" }
    ]
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with([ { "key" => "booking", "name" => "Booking" } ]))
    booking = RecordingClient.new([ { name: "search_slots", description: "Open slots.", parameters: { type: "object" } } ])
    dispatcher.instance_variable_get(:@clients)["booking"] = booking

    # Nothing in the name says where it lives until the server has listed it.
    assert_not dispatcher.dispatchable?("search_slots")

    assert_equal %w[search_slots], dispatcher.tool_definitions.map { |tool| tool[:name] }
    assert dispatcher.dispatchable?("search_slots")
    assert_equal({ text: "search_slots answered" }, dispatcher.call("search_slots", { "day" => "friday" }))
    assert_equal [ [ "search_slots", { "day" => "friday" } ] ], booking.calls
    # A tool no server of the agent's listed is still the toolbox's.
    assert_not dispatcher.dispatchable?("run_command")
    assert_nil dispatcher.call("run_command", {})
  end

  # The catalog hints browser_navigate to playwright, which this agent has not
  # enabled (and could not call: it is stdio). The server it did enable lists
  # the tool, so that server answers — a hint naming a server the agent cannot
  # reach must not strand a tool the model was offered.
  test "a listed tool the catalog hints to a server the agent has not enabled is dispatched where it was listed" do
    ActionAgent.mcp_catalog = [
      { key: "browser", name: "Browser", transport: "http", url: "https://browser.example/mcp" }
    ]
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with([ { "key" => "browser", "name" => "Browser" } ]))
    browser = RecordingClient.new([ { name: "browser_navigate", description: "Opens a page.", parameters: { type: "object" } } ])
    dispatcher.instance_variable_get(:@clients)["browser"] = browser

    assert_equal "playwright", ActionAgent::EvaluationToolResolver.new(nil).server_key_for("browser_navigate")
    assert_not dispatcher.dispatchable?("browser_navigate")

    assert_equal %w[browser_navigate], dispatcher.tool_definitions.map { |tool| tool[:name] }
    assert dispatcher.dispatchable?("browser_navigate")
    assert_equal({ text: "browser_navigate answered" }, dispatcher.call("browser_navigate", { "url" => "https://example.com" }))
    assert_equal [ [ "browser_navigate", { "url" => "https://example.com" } ] ], browser.calls
  end

  # The Tools tab saves {key, name, tools: [...]} when some of a server's tools
  # are switched off, and tools: [] when all are. A switched-off tool is
  # neither offered nor sent to the server, however the server lists it.
  test "a tool the agent's entry switches off is neither offered nor dispatched" do
    ActionAgent.mcp_catalog = [
      { key: "booking", name: "Booking", transport: "http", url: "https://booking.example/mcp" }
    ]
    listing = [
      { name: "search_slots", description: "Open slots.", parameters: { type: "object" } },
      { name: "cancel_all_bookings", description: "Cancels everything.", parameters: { type: "object" } }
    ]

    narrowed = ActionAgent::MCPToolDispatcher.new(agent_with([ { "key" => "booking", "tools" => [ "search_slots" ] } ]))
    booking = RecordingClient.new(listing)
    narrowed.instance_variable_get(:@clients)["booking"] = booking

    assert_equal %w[search_slots], narrowed.tool_definitions.map { |tool| tool[:name] }
    assert narrowed.dispatchable?("search_slots")
    assert_not narrowed.dispatchable?("cancel_all_bookings")
    assert_nil narrowed.call("cancel_all_bookings", {})
    assert_equal({ text: "search_slots answered" }, narrowed.call("search_slots", {}))
    assert_equal [ [ "search_slots", {} ] ], booking.calls

    none = ActionAgent::MCPToolDispatcher.new(agent_with([ { "key" => "booking", "name" => "Booking", "tools" => [] } ]))
    silent = RecordingClient.new(listing)
    none.instance_variable_get(:@clients)["booking"] = silent

    assert_empty none.tool_definitions
    assert_nil none.call("search_slots", {})
    assert_nil none.call("cancel_all_bookings", {})
    assert_empty silent.calls
  end

  # A catalog hint names the server without its listing, so the allow-list
  # has to hold on that path too.
  test "a hinted tool the agent's entry switches off is not dispatched" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with([ { "key" => "records", "tools" => [ "find_records" ] } ]))

    assert dispatcher.dispatchable?("find_records")
    assert dispatcher.dispatchable?("mcp__records__find_records")
    assert_not dispatcher.dispatchable?("count_records")
    assert_not dispatcher.dispatchable?("mcp__records__count_records")
    assert_nil dispatcher.call("count_records", {})
  end

  test "a server that stops answering stops being where its tools are dispatched" do
    ActionAgent.mcp_catalog = [
      { key: "booking", name: "Booking", transport: "http", url: "https://booking.example/mcp" }
    ]
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(%w[booking]))
    clients = dispatcher.instance_variable_get(:@clients)
    clients["booking"] = StubClient.new(tools: [ { name: "search_slots", description: "", parameters: {} } ])
    dispatcher.tool_definitions
    assert dispatcher.dispatchable?("search_slots")

    clients["booking"] = StubClient.new(raises: "unreachable")
    dispatcher.tool_definitions

    assert_not dispatcher.dispatchable?("search_slots")
  end

  test "an observed agent with a reachable server may execute" do
    agent = agent_with(%w[records])
    agent.status = :observed

    assert_nothing_raised { agent.ensure_executable! }
  end

  test "an observed agent with nothing to call is still refused" do
    agent = agent_with([])
    agent.status = :observed

    error = assert_raises(ActionAgent::Agent::ObservedAgentError) { agent.ensure_executable! }
    assert_match(/no reachable MCP server/, error.message)
  end
end

# The same gap, end to end against a checkout sandbox's runtime (#489): an
# agent enabling "sandbox:<id>" — bare, or as the {key, name} entry the Tools
# tab saves — is offered the runtime's tools and must have a call to one of
# them reach the runtime, carrying the bearer token its MCP endpoint expects.
#
# These stub the endpoint itself rather than the client: VCR lets through a
# request WebMock holds a stub for, and the header on the wire is the point.
class MCPToolDispatcherRuntimeTest < ActiveSupport::TestCase
  RUNTIME_URL = "http://127.0.0.1:4100/activeagents/mcp"
  RUNTIME_TOKEN = "aa_runtime_dispatch_s3cret"

  setup do
    ActionAgent::SandboxSession.delete_all
    @session = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/docs", repository_ref: "main"
    )
    # The repository check reads a GitHub selection this test has no need of.
    @session.save!(validate: false)
    @session.mark_ready!(cloud_run_url: "http://127.0.0.1:4100", runtime_mcp_url: RUNTIME_URL, runtime_mcp_token: RUNTIME_TOKEN)
  end

  def agent_with(servers)
    ActionAgent::Agent.new(name: "Checkout agent", status: :draft, provider: "openai",
                           model: "gpt-4o-mini", mcp_servers: servers, tools: [])
  end

  # The runtime's MCP endpoint, answering only a request that carries its
  # token: initialize, the initialized notification, tools/list, tools/call.
  def stub_runtime
    stub_request(:post, RUNTIME_URL)
      .with(headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" })
      .to_return do |request|
        payload = JSON.parse(request.body)
        result =
          case payload["method"]
          when "initialize" then { protocolVersion: "2025-03-26", capabilities: { tools: {} } }
          when "tools/list"
            { tools: [ { name: "lookup_order", description: "Find an order by id.",
                         inputSchema: { type: "object", properties: { id: { type: "string" } } } } ] }
          when "tools/call"
            { content: [ { type: "text", text: "order #{payload.dig('params', 'arguments', 'id')} shipped" } ] }
          end

        if payload.key?("id")
          { status: 200, body: { jsonrpc: "2.0", id: payload["id"], result: result }.to_json,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "runtime-session" } }
        else
          { status: 202, body: "" }
        end
      end
  end

  def assert_dispatched_to_runtime(servers)
    stub_runtime
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with(servers))

    assert_equal %w[lookup_order], dispatcher.tool_definitions.map { |tool| tool[:name] }
    assert dispatcher.dispatchable?("lookup_order")
    assert_equal({ text: "order A-17 shipped" }, dispatcher.call("lookup_order", { "id" => "A-17" }))

    assert_requested(:post, RUNTIME_URL, headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" }, times: 1) do |request|
      payload = JSON.parse(request.body)
      payload["method"] == "tools/call" && payload.dig("params", "name") == "lookup_order" &&
        payload.dig("params", "arguments") == { "id" => "A-17" }
    end
  end

  test "a runtime enabled by its bare key dispatches a bare tool name to the runtime" do
    assert_dispatched_to_runtime([ @session.runtime_server_key ])
  end

  test "a runtime enabled as a key and name dispatches a bare tool name to the runtime" do
    assert_dispatched_to_runtime([ { "key" => @session.runtime_server_key, "name" => "acme/docs@main (sandbox)" } ])
  end

  test "a runtime given for one run dispatches as if the agent enabled it, and only a runtime is taken" do
    stub_runtime
    agent = agent_with([])
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent, extra_server_keys: [ @session.runtime_server_key, "playwright", "" ])

    assert_equal [ @session.runtime_server_key ], dispatcher.extra_server_keys, "a catalog server is not the run's to add"
    assert dispatcher.any_reachable_server?
    assert_equal %w[lookup_order], dispatcher.tool_definitions.map { |tool| tool[:name] }
    assert_equal({ text: "order A-17 shipped" }, dispatcher.call("lookup_order", { "id" => "A-17" }))
    assert_equal [], agent.mcp_servers
    assert_not ActionAgent::MCPToolDispatcher.new(agent).any_reachable_server?, "the next run without it does not reach it"
  end

  test "a runtime given for one run still resolves among the agent's owner's sessions only" do
    WebMock::RequestRegistry.instance.reset!
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @session.update_columns(user_id: owner.id)
    agent = agent_with([])
    agent.user_id = stranger.id

    dispatcher = ActionAgent::MCPToolDispatcher.new(agent, extra_server_keys: [ @session.runtime_server_key ])

    assert_empty dispatcher.tool_definitions
    assert_nil dispatcher.call("lookup_order", { "id" => "A-17" })
    assert_not_requested(:post, RUNTIME_URL)
  ensure
    ActionAgent.user_class = nil
  end

  test "a runtime that has expired is neither offered nor dispatched to" do
    stub_runtime
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent_with([ @session.runtime_server_key ]))
    dispatcher.tool_definitions
    # Its endpoint left in place: liveness alone must stop the call.
    @session.update!(status: :expired)

    assert_nil dispatcher.call("lookup_order", { "id" => "A-17" })
    assert_empty ActionAgent::MCPToolDispatcher.new(agent_with([ @session.runtime_server_key ])).tool_definitions
    assert_not_requested(:post, RUNTIME_URL) { |request| JSON.parse(request.body)["method"] == "tools/call" }
  end
end
