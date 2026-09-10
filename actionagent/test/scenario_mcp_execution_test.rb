# frozen_string_literal: true

require "test_helper"

# Exercises native scenario replay through the provider's real tool-calling
# loop and the engine's MCP client. Only HTTP is stubbed; execution, progress
# events, traces and evaluation results all use their production path.
class ActionAgentScenarioMCPExecutionTest < ActiveSupport::TestCase
  def setup
    ActionAgent::Agent.delete_all
    @original_catalog = ActionAgent.mcp_catalog
    @original_credentials = ActionAgent.provider_credentials_resolver
    ActionAgent.mcp_catalog = [ { key: "host", transport: "streamable_http", url: "https://host.test/mcp" } ]
    ActionAgent.provider_credentials_resolver = ->(_owner, provider) { { access_token: "test-key" } if provider == "anthropic" }
  end

  def teardown
    ActionAgent.mcp_catalog = @original_catalog
    ActionAgent.provider_credentials_resolver = @original_credentials
  end

  def build_suite(tool_name: "healthcheck", tools: nil, prompts: [ "Check database health" ])
    @tool_name = tool_name
    agent = ActionAgent::Agent.create!(
      name: "Production Health", status: :observed, provider: "anthropic", model: "claude-haiku-4-5",
      instructions: "Use #{tool_name} to report the host's actual status.", tools: tools || [ tool_name ], mcp_servers: [ "host" ]
    )
    evaluation = agent.evaluations.new(name: "Host health", judge_kind: "rules", criteria: [])
    prompts.each_with_index do |prompt, index|
      evaluation.scenarios.build(key: "health_#{index}", prompt: prompt, expectations: { "tools" => [ tool_name ] })
    end
    evaluation.save!
    evaluation
  end

  def run_suite(evaluation)
    runner = ActionAgent::ScenarioEvaluationRunner.new(evaluation)
    # This regression scores deterministic tool evidence, not an LLM judge.
    Resolv.stub(:getaddresses, [ "127.0.0.1" ]) do
      runner.stub(:evals_judge, nil) { runner.call }
    end
  end

  def stub_host(error: false, discovery_status: 200)
    @mcp_requests = []
    stub_request(:post, "https://host.test/mcp").to_return do |request|
      payload = JSON.parse(request.body)
      @mcp_requests << payload
      if payload["method"] == "notifications/initialized"
        next { status: 202, body: "" }
      end
      if payload["method"] == "tools/list" && discovery_status != 200
        next { status: discovery_status, body: "Service unavailable" }
      end

      result = case payload.fetch("method")
      when "initialize"
        { protocolVersion: ActionAgent::MCPClient::PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: "host", version: "1" } }
      when "tools/list"
        { tools: [ {
          name: @tool_name, description: "Read actual component health from this host",
          inputSchema: { type: "object", properties: { component: { type: "string" } }, required: [ "component" ] }
        } ] }
      when "tools/call"
        { isError: error, content: [ { type: "text", text: error ? "Database is unavailable" : "Database is healthy" } ] }
      else
        flunk "Unexpected MCP method #{payload['method']}"
      end

      {
        status: 200,
        headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "health-session" },
        body: { jsonrpc: "2.0", id: payload.fetch("id"), result: result }.to_json
      }
    end
  end

  def stub_provider(call_tool: true)
    @provider_requests = []
    stub_request(:post, "https://api.anthropic.com/v1/messages").to_return do |request|
      payload = JSON.parse(request.body)
      @provider_requests << payload
      has_result = payload.fetch("messages").any? do |message|
        Array(message["content"]).any? { |content| content.is_a?(Hash) && content["type"] == "tool_result" }
      end
      invoke = call_tool && !has_result
      content = if invoke
        [ { type: "tool_use", id: "tool_health", name: @tool_name, input: { component: "database" } } ]
      else
        [ { type: "text", text: "Healthcheck finished." } ]
      end
      {
        status: 200, headers: { "Content-Type" => "application/json" },
        body: {
          id: "msg_health_#{@provider_requests.size}", type: "message", role: "assistant",
          model: payload.fetch("model"), content: content, stop_reason: invoke ? "tool_use" : "end_turn",
          stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 10 }
        }.to_json
      }
    end
  end

  test "an observed scenario calls its host tool and persists the actual execution evidence" do
    evaluation = build_suite
    stub_host
    stub_provider

    run = run_suite(evaluation)
    result = run.scenario_results.sole

    assert_equal "complete", run.status
    assert_equal "passed", result.status, result.error_message
    assert_equal 1.0, result.scores["expected_tools"]
    assert_equal 1.0, result.scores["tools_succeeded"]
    assert_equal 2, @provider_requests.size
    offered = @provider_requests.first.fetch("tools").sole
    assert_equal "healthcheck", offered["name"]
    assert_equal [ "component" ], offered.dig("input_schema", "required")
    call = @mcp_requests.select { |request| request["method"] == "tools/call" }.sole
    assert_equal({ "name" => "healthcheck", "arguments" => { "component" => "database" } }, call["params"])
    assert_equal [ "healthcheck" ], result.agent_run.output_metadata["tool_calls"]
    tool_call = result.tool_calls.sole
    assert_equal "healthcheck", tool_call["name"]
    assert_equal({ "component" => "database" }, tool_call["arguments"])
    assert_equal false, tool_call["error"]
    assert_includes tool_call["detail"], "Database is healthy"
    trace = ActionAgent.trace_model.find_by!(trace_id: result.agent_run.trace_id)
    span = trace.spans.find { |entry| entry.dig("attributes", "tool.name") == "healthcheck" }
    assert_equal "host", span.dig("attributes", "tool.mcp_server")
    assert_equal "Database is healthy", span.dig("attributes", "tool.output.result")
    assert evaluation.agent.reload.observed?
  end

  test "a host tool named prompt does not overwrite the runtime agent's prompt method" do
    evaluation = build_suite(tool_name: "prompt")
    stub_host
    stub_provider

    result = run_suite(evaluation).scenario_results.sole

    assert_equal "passed", result.status, result.error_message
    assert_equal "prompt", result.tool_calls.sole["name"]
    assert_equal "prompt", @provider_requests.first.fetch("tools").sole["name"]
    call = @mcp_requests.select { |request| request["method"] == "tools/call" }.sole
    assert_equal "prompt", call.dig("params", "name")
    assert_equal({ "component" => "database" }, call.dig("params", "arguments"))
  end

  test "a host tool error is persisted as a tool_error diagnosis" do
    evaluation = build_suite
    stub_host(error: true)
    stub_provider

    result = run_suite(evaluation).scenario_results.sole

    assert_equal "failed", result.status
    assert_equal "tool_error", result.fault
    assert_equal true, result.tool_calls.sole["error"]
    assert_includes result.tool_calls.sole["detail"], "Database is unavailable"
    assert_includes result.recommendation, "healthcheck"
  end

  test "a declared host tool omitted by the model is diagnosed as available" do
    evaluation = build_suite
    stub_host
    stub_provider(call_tool: false)

    result = run_suite(evaluation).scenario_results.sole

    assert_equal "expected_tool_not_called", result.fault
    assert_empty result.diagnosis.dig("evidence", "unavailable")
    assert_empty @mcp_requests.select { |request| request["method"] == "tools/call" }
  end

  test "diagnosis uses the live MCP roster for tools named like builder categories" do
    evaluation = build_suite(tool_name: "memory")
    stub_host
    stub_provider(call_tool: false)

    result = run_suite(evaluation).scenario_results.sole

    assert_equal "expected_tool_not_called", result.fault
    assert_empty result.diagnosis.dig("evidence", "unavailable")
    assert_equal [ "memory" ], @provider_requests.first.fetch("tools").map { |tool| tool["name"] }
  end

  test "unresolved declared tools fail every scenario before provider generation" do
    evaluation = build_suite(tools: [ "missing_healthcheck" ], prompts: [ "Check database health", "Check cache health" ])
    stub_host
    stub_provider

    run = run_suite(evaluation)

    assert_equal "complete", run.status
    assert_equal 2, run.scenario_results.count
    run.scenario_results.each do |result|
      assert_equal "errored", result.status
      assert_equal "run_error", result.fault
      assert_includes result.error_message, "missing_healthcheck"
      assert result.agent_run.failed?
    end
    assert_empty @provider_requests
  end

  test "MCP discovery failure remains an actionable per-scenario run error" do
    evaluation = build_suite(prompts: [ "Check database health", "Check cache health" ])
    stub_host(discovery_status: 503)
    stub_provider

    run = run_suite(evaluation)

    assert_equal "complete", run.status
    assert_equal 2, run.scenario_results.count
    run.scenario_results.each do |result|
      assert_equal "errored", result.status
      assert_equal "run_error", result.fault
      assert_includes result.error_message, "host"
      assert_includes result.error_message, "503"
      assert result.agent_run.failed?
    end
    assert_empty @provider_requests
  end
end
