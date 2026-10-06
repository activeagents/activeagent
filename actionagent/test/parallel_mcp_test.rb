# frozen_string_literal: true

require "test_helper"

class ParallelMCPTest < ActionDispatch::IntegrationTest
  ENDPOINT = "https://search.parallel.ai/mcp"

  test "Parallel is listed as a keyless HTTP service without sandbox provisioning" do
    get "/activeagents/api/mcp_servers/parallel"

    assert_response :success
    server = JSON.parse(response.body)["server"]
    assert_equal "Parallel Search", server["name"]
    assert_equal ENDPOINT, server["url"]
    assert_equal "http", server["transport"]
    assert_empty server["requires_credentials"]
    assert_equal false, server["launchable"]
    assert_empty server["tools"], "generic tool names must not change attribution for other servers"
  end

  test "an agent must enable Parallel before it can discover or call its tools" do
    dispatcher = ActionAgent::MCPToolDispatcher.new(build_agent([]))

    assert_empty dispatcher.tool_definitions
    assert_nil dispatcher.call("web_search", { "objective" => "Ruby documentation" })
    assert_not dispatcher.any_reachable_server?
  end

  test "saved Parallel selection discovers and calls search and fetch anonymously" do
    agent = build_agent([ "parallel" ])
    agent.save!
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent.reload)

    with_parallel_server do |requests|
      assert_equal %w[web_search web_fetch], dispatcher.tool_definitions.map { |tool| tool[:name] }
      assert_empty dispatcher.discovery_errors

      search = { "objective" => "Find Ruby documentation", "search_queries" => [ "Ruby documentation" ] }
      fetch = { "urls" => [ "https://www.ruby-lang.org/en/documentation/" ] }
      assert_includes dispatcher.call("web_search", search)[:text], "Ruby documentation"
      assert_includes dispatcher.call("web_fetch", fetch)[:text], "Ruby is a programming language"

      assert_equal %w[initialize notifications/initialized tools/list tools/call tools/call], requests.map { |request| request[:body]["method"] }
      assert_equal [ search, fetch ], requests.last(2).map { |request| request[:body].dig("params", "arguments") }
      requests.each do |request|
        assert_equal "ActionAgent/#{ActionAgent::VERSION}", request[:headers]["User-Agent"]
        assert_nil request[:headers]["Authorization"]
        assert_nil request[:headers]["X-Api-Key"]
      end
    end
  ensure
    agent&.destroy!
  end

  test "saved tool restrictions keep fetch disabled" do
    agent = build_agent([ { "key" => "parallel", "tools" => [ "web_search" ] } ])
    agent.save!
    dispatcher = ActionAgent::MCPToolDispatcher.new(agent.reload)

    with_parallel_server do |requests|
      assert_equal %w[web_search], dispatcher.tool_definitions.map { |tool| tool[:name] }
      assert_nil dispatcher.call("web_fetch", { "urls" => [ "https://www.ruby-lang.org/" ] })
      assert_equal 3, requests.size
    end
  ensure
    agent&.destroy!
  end

  private

  def build_agent(servers)
    ActionAgent::Agent.new(name: "Parallel research", provider: "openai", model: "gpt-4o-mini", mcp_servers: servers)
  end

  # Synthetic protocol responses keep this test deterministic and keyless.
  # The real MCPClient and dispatcher still perform every HTTP exchange.
  def with_parallel_server
    requests = []
    tools = [
      { name: "web_search", description: "Search the web", inputSchema: { type: "object", properties: { objective: { type: "string" }, search_queries: { type: "array", items: { type: "string" } } }, required: %w[objective search_queries] } },
      { name: "web_fetch", description: "Fetch pages", inputSchema: { type: "object", properties: { urls: { type: "array", items: { type: "string" } } }, required: [ "urls" ] } }
    ]
    VCR.turned_off do
      stub_request(:post, ENDPOINT).to_return do |request|
        body = JSON.parse(request.body)
        requests << { body: body, headers: request.headers }
        result = case body["method"]
        when "initialize"
          { protocolVersion: "2025-03-26", capabilities: { tools: {} }, serverInfo: { name: "Synthetic search", version: "1" } }
        when "tools/list"
          { tools: tools }
        when "tools/call"
          text = body.dig("params", "name") == "web_search" ? "Ruby documentation: https://www.ruby-lang.org/en/documentation/" : "Ruby is a programming language."
          { content: [ { type: "text", text: text } ], isError: false }
        end
        { status: 200, headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: body["id"], result: result }.to_json }
      end
      yield requests
    end
  end
end
