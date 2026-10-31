# frozen_string_literal: true

require "test_helper"

# The outbound guard on a user-supplied MCP server URL: refused when saved if
# it names a non-public address, and refused when called if its host
# resolves to one.
class MCPHostGuardTest < ActiveSupport::TestCase
  Guard = ActionAgent::MCPHostGuard

  teardown do
    Guard.resolver = nil
    ActionAgent.allow_private_mcp_hosts = false
  end

  test "public and non-public addresses" do
    %w[93.184.216.34 8.8.8.8 2606:2800:220:1:248:1893:25c8:1946].each do |address|
      assert Guard.public_address?(address), "#{address} is public"
    end

    %w[
      127.0.0.1 10.1.2.3 172.31.255.1 192.168.0.1 169.254.169.254 0.0.0.0 100.64.0.1 224.0.0.1
      ::1 :: fd12::1 fe80::1 ::ffff:10.0.0.1 ff02::1 not-an-address
    ].each do |address|
      assert_not Guard.public_address?(address), "#{address} is not public"
    end
  end

  test "a host is refused unless every address it resolves to is public" do
    Guard.resolver = ->(host) { { "app.example.com" => %w[93.184.216.34], "split.example.com" => %w[93.184.216.34 10.0.0.8] }.fetch(host, []) }

    assert_equal %w[93.184.216.34], Guard.public_addresses!("app.example.com")
    error = assert_raises(ActionAgent::MCPClient::Error) { Guard.public_addresses!("split.example.com") }
    assert_match(/10\.0\.0\.8/, error.message)
    assert_match(/allow_private_mcp_hosts/, error.message)
    assert_raises(ActionAgent::MCPClient::Error) { Guard.public_addresses!("nowhere.example.com") }
  end

  test "a public-only client refuses a host that resolves privately, before sending anything" do
    Guard.resolver = ->(_host) { %w[127.0.0.1] }
    stub = stub_request(:post, "https://rebind.example.com/mcp")
    client = ActionAgent::MCPClient.new(url: "https://rebind.example.com/mcp", public_only: true)

    error = assert_raises(ActionAgent::MCPClient::Error) { client.list_tools }

    assert_match(/private, loopback or link-local/, error.message)
    assert_not_requested stub
  end

  test "a public-only client connects to the address it checked" do
    resolutions = 0
    Guard.resolver = lambda do |_host|
      resolutions += 1
      %w[93.184.216.34]
    end
    stub_request(:post, "https://app.example.com/mcp").to_return do |request|
      payload = JSON.parse(request.body)
      body = payload["method"] == "tools/list" ? { tools: [ { name: "find_order" } ] } : {}
      payload.key?("id") ? { status: 200, body: { jsonrpc: "2.0", id: payload["id"], result: body }.to_json } : { status: 202, body: "" }
    end
    client = ActionAgent::MCPClient.new(url: "https://app.example.com/mcp", public_only: true)

    assert_equal %w[find_order], client.list_tools.map { |tool| tool[:name] }
    assert_equal "93.184.216.34", client.send(:connect_address)
    assert_equal 1, resolutions, "one resolution serves every request of the client"
  end
end
