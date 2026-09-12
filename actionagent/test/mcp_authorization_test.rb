# frozen_string_literal: true

require "test_helper"

# The agents-as-MCP facade, asked on whose behalf it is running.
#
# A key authenticates the request, so the facade already knows who is calling;
# what it never did was tell the run. Without that, an agent reached over MCP
# runs unattributed, and a host scope written correctly against Pundit
# answers "no tickets" to a caller who has plenty — a wrong answer wearing a
# right one's clothes.
class McpAuthorizationTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::ApiKey.delete_all
    @agent = ActionAgent::Agent.create!(
      name: "Records", slug: "records", provider: "mock", model: "mock", status: :active
    )
    @key = ActionAgent::ApiKey.create!(name: "Test key")
  end

  def teardown
    ActionAgent.agent_actor_resolver = nil
  end

  def rpc(method, params = {}, token: @key.token)
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
    JSON.parse(response.body)
  end

  test "a tool call runs on behalf of the caller the host resolves" do
    resolved = @agent # any object; the engine never interprets one
    seen = nil
    ActionAgent.agent_actor_resolver = ->(_controller) { resolved }

    ActionAgent::AgentExecutionService.stub(:call, ->(_agent, run) {
      seen = run.actor
      { output: "done", metadata: {}, usage: {} }
    }) do
      rpc("tools/call", { name: "run_records", arguments: { message: "hello" } })
    end

    assert_response :success
    assert_equal resolved, seen, "the run should execute as the resolved caller"
  end

  test "with no resolver the key's own owner is the caller" do
    seen = :unset

    ActionAgent::AgentExecutionService.stub(:call, ->(_agent, run) {
      seen = run.actor
      { output: "done", metadata: {}, usage: {} }
    }) do
      rpc("tools/call", { name: "run_records", arguments: { message: "hello" } })
    end

    # This install configures no owner model, so the key owns nothing and the
    # run is unattributed — the safe direction. What matters is that it is
    # the key's identity that decides, not a default.
    assert_nil @key.owner
    assert_nil seen
  end

  test "a refusal answers as a JSON-RPC error rather than as an empty result" do
    ActionAgent::AgentExecutionService.stub(:call, ->(_agent, _run) {
      raise ActiveAgent::NotAuthorized.new(action: "run_records")
    }) do
      body = rpc("tools/call", { name: "run_records", arguments: { message: "hello" } })

      assert_response :success
      assert_equal(-32003, body.dig("error", "code"))
      assert_match(/not allowed/, body.dig("error", "message"))
      assert_nil body["result"], "a refused call has no result to read"
    end
  end

  test "a run that merely failed is still a tool result, not a refusal" do
    ActionAgent::AgentExecutionService.stub(:call, ->(_agent, _run) { raise "provider exploded" }) do
      body = rpc("tools/call", { name: "run_records", arguments: { message: "hello" } })

      assert_nil body["error"], "a broken run is reported to the model, not to the transport"
      assert_equal true, body.dig("result", "isError")
      assert_match(/provider exploded/, body.dig("result", "content", 0, "text"))
    end
  end

  test "an unauthenticated request never reaches an agent at all" do
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call" }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end
end
