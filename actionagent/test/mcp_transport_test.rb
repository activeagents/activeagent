# frozen_string_literal: true

require "test_helper"

# The MCP facade's Streamable HTTP contract on verbs it does not serve, and
# the catalog's description of the facade itself (#389).
class MCPTransportTest < ActionDispatch::IntegrationTest
  test "a protocol client's GET is answered 405 with Allow: POST" do
    get "/activeagents/mcp", headers: { "Accept" => "text/event-stream" }

    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
  end

  test "a bare GET (curl) is answered 405 rather than with the dashboard page" do
    get "/activeagents/mcp", headers: { "Accept" => "*/*" }

    assert_response :method_not_allowed
  end

  test "DELETE (session end) is answered 405" do
    delete "/activeagents/mcp"

    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
  end

  test "a browser's GET still opens the dashboard's MCP Services deep link" do
    get "/activeagents/mcp", headers: { "Accept" => "text/html,application/xhtml+xml,*/*;q=0.8" }

    assert_response :success
    assert_includes response.content_type, "text/html"
  end

  # The index is a union of catalog and detected servers, so a server it
  # lists must be fetchable individually even when the catalog has never
  # heard of it (#388).
  test "shows a server the index lists but the catalog does not describe" do
    ActionAgent::Agent.delete_all
    ActionAgent::Agent.create!(name: "MCP Probe", provider: "openai", model: "gpt-4o", mcp_servers: [ "custom-thing" ])

    get "/activeagents/api/mcp_servers/custom-thing"

    assert_response :success
    server = JSON.parse(response.body)["server"]
    assert_equal "custom-thing", server["key"]
    assert_equal false, server["known"]
    assert_equal "configured", server["status"]
  ensure
    ActionAgent::Agent.delete_all
  end

  test "the first-party catalog entry names the endpoint at the real mount" do
    get "/activeagents/api/mcp_servers/activeagents"

    assert_response :success
    server = JSON.parse(response.body)["server"]
    assert_equal "/activeagents/mcp", server["url"]

    get "/activeagents/api/mcp_servers"

    assert_response :success
    entry = JSON.parse(response.body)["catalog"].find { |row| row["key"] == "activeagents" }
    assert_equal "/activeagents/mcp", entry["url"]
    assert_empty entry["tools"], "the facade's tools are run_<slug>; a static hint list cannot name them"
  end
end
