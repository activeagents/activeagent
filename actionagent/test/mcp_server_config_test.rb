# frozen_string_literal: true

require "test_helper"

# A dashboard user's own remote MCP server: its URL guard, its write-only
# headers, its owner scoping and the connection test that discovers its
# tools.
class MCPServerConfigTest < ActiveSupport::TestCase
  URL = "https://app.example.com/mcp"

  # Stands in for MCPClient in #test_connection!.
  class StubClient
    def initialize(tools: [], raises: nil)
      @tools = tools
      @raises = raises
    end

    def list_tools
      raise ActionAgent::MCPClient::Error, @raises if @raises

      @tools
    end
  end

  setup do
    ActionAgent::MCPServerConfig.delete_all
    ActionAgent.allow_private_mcp_hosts = false
  end

  teardown do
    ActionAgent.allow_private_mcp_hosts = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
  end

  def config(**attributes)
    ActionAgent::MCPServerConfig.new(name: "Orders", url: URL, **attributes)
  end

  test "a public https URL is valid" do
    assert config.valid?
  end

  test "only http and https URLs are accepted" do
    %w[ftp://app.example.com/mcp file:///etc/passwd javascript:alert(1) app.example.com/mcp].each do |url|
      record = config(url: url)

      assert_not record.valid?, "#{url} must be refused"
      assert_includes record.errors[:url].join, "http"
    end
  end

  test "a URL carrying a user name or password is refused" do
    record = config(url: "https://user:secret@app.example.com/mcp")

    assert_not record.valid?
    assert_match(/header/, record.errors[:url].join)
  end

  test "loopback, private, link-local and localhost URLs are refused unless the host app allows them" do
    urls = %w[
      http://127.0.0.1:3000/mcp http://localhost:3000/mcp http://api.localhost/mcp http://10.0.0.5/mcp
      http://192.168.1.10/mcp http://172.16.4.2/mcp http://169.254.169.254/latest http://[::1]:3000/mcp
      http://[fd00::1]/mcp http://[fe80::1]/mcp http://0.0.0.0:3000/mcp http://[::ffff:127.0.0.1]/mcp
    ]

    urls.each { |url| assert_not config(url: url).valid?, "#{url} must be refused" }

    ActionAgent.allow_private_mcp_hosts = true
    urls.each { |url| assert config(url: url).valid?, "#{url} is allowed once the host opts in" }
  end

  test "header values are encrypted at rest and never part of a listing" do
    record = config(headers: { "Authorization" => "Bearer orders-s3cret-token-value" })
    record.save!

    raw = ActionAgent::MCPServerConfig.connection.select_value(
      "SELECT secret_headers FROM #{ActionAgent::MCPServerConfig.table_name} WHERE id = #{record.id}"
    )
    assert_not_includes raw, "orders-s3cret-token-value"
    assert_equal({ "Authorization" => "Bearer orders-s3cret-token-value" }, record.reload.headers)

    assert_nil record.listing[:headers]
    assert_not_includes record.listing.to_json, "s3cret"
    assert_not_includes record.as_api_json.to_json, "s3cret"
    assert_equal [ { name: "Authorization", hint: "••••alue" } ], record.header_hints
  end

  test "a short header value is masked entirely" do
    assert_equal [ { name: "X-Api-Key", hint: "••••" } ], config(headers: { "X-Api-Key" => "abc123" }).header_hints
  end

  test "a header sent blank keeps its stored value, and a header left out is removed" do
    record = config(headers: { "Authorization" => "Bearer old-token", "X-Tenant" => "acme" })
    record.save!

    record.assign_headers([ { "name" => "authorization", "value" => "" }, { "name" => "X-Region", "value" => "eu" } ])

    assert_equal({ "authorization" => "Bearer old-token", "X-Region" => "eu" }, record.headers)
  end

  test "a new header with no value, a reserved header and an invalid name are refused" do
    record = config
    record.assign_headers([ { "name" => "X-New", "value" => "" } ])
    assert_not record.valid?
    assert_match(/X-New needs a value/, record.errors[:headers].join)

    assert_not config(headers: { "Content-Type" => "text/plain" }).valid?
    assert_not config(headers: { "Mcp-Session-Id" => "x" }).valid?
    assert_not config(headers: { "Bad Name" => "x" }).valid?
    assert_not config(headers: { "X-Token" => "a\r\nInjected: yes" }).valid?
  end

  test "a key resolves among its owner's configurations only" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    owner = User.create!(name: "Owner", email: "owner-#{SecureRandom.hex(3)}@example.com", age: 30)
    stranger = User.create!(name: "Stranger", email: "stranger-#{SecureRandom.hex(3)}@example.com", age: 30)
    record = config(headers: { "Authorization" => "Bearer owner-token" })
    record.account_id = owner.id
    record.save!

    entry = ActionAgent::MCPServerConfig.server_entry(record.server_key, owner: owner)
    assert_equal URL, entry[:url]
    assert_equal({ "Authorization" => "Bearer owner-token" }, entry[:headers])
    assert entry[:public_only]

    assert_nil ActionAgent::MCPServerConfig.server_entry(record.server_key, owner: stranger)
    assert_nil ActionAgent::MCPServerConfig.server_entry(record.server_key, owner: nil)
    assert_nil ActionAgent::MCPServerConfig.server_entry("custom:#{record.id}x", owner: owner)
    assert_nil ActionAgent::MCPServerConfig.server_entry("custom:#{record.id + 1}", owner: owner)
  end

  test "a disabled configuration resolves to no connection" do
    record = config(enabled: false)
    record.save!

    assert_nil ActionAgent::MCPServerConfig.server_entry(record.server_key, owner: nil)
    assert_equal false, record.listing[:enabled]
  end

  test "the listing drops the query string, the connection keeps it" do
    record = config(url: "https://app.example.com/mcp?token=abc")
    record.save!

    assert_equal "https://app.example.com/mcp", record.listing[:url]
    assert_equal "https://app.example.com/mcp?token=abc", record.server_entry[:url]
  end

  test "a connection test records the tools the server lists" do
    record = config
    record.save!

    result = record.test_connection!(client: StubClient.new(tools: [ { name: "find_order" }, { name: "refund_order" } ]))

    assert result[:ok]
    assert_equal %w[find_order refund_order], result[:tools]
    record.reload
    assert_equal "ok", record.last_test_status
    assert_equal %w[find_order refund_order], record.tool_names_list
    assert_not_nil record.last_tested_at
    assert_equal %w[find_order refund_order], record.listing[:tools]
  end

  test "a failed connection test records why and keeps the tools found before" do
    record = config(tool_names: %w[find_order])
    record.save!

    result = record.test_connection!(client: StubClient.new(raises: "MCP server returned HTTP 401"))

    assert_not result[:ok]
    assert_equal "MCP server returned HTTP 401", result[:error]
    record.reload
    assert_equal "failed", record.last_test_status
    assert_equal "MCP server returned HTTP 401", record.last_test_error
    assert_equal %w[find_order], record.tool_names_list
  end
end
