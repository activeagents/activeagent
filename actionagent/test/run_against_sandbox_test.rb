# frozen_string_literal: true

require "test_helper"

# Evaluating an agent against a checkout sandbox without editing the agent:
# `sandbox_id` on POST /api/evaluations/:id/run (and on the runner's
# /api/agents/:id/execute and /test) makes that run's tool calls reach the
# sandbox's app runtime, as if the agent listed "sandbox:<id>" in
# mcp_servers. The runtime's MCP endpoint and the model are stubbed on the
# wire: the Bearer header reaching the runtime is the point.
class RunAgainstSandboxTest < ActionDispatch::IntegrationTest
  RUNTIME_URL = "http://127.0.0.1:4100/activeagents/mcp"
  RUNTIME_TOKEN = "aa_runtime_run_against_s3cret"
  CHAT_URL = "https://api.openai.com/v1/chat/completions"

  def setup
    # Counted per test: the assertions below say how often the runtime was
    # called.
    WebMock::RequestRegistry.instance.reset!
    ActionAgent::Agent.delete_all
    ActionAgent::SandboxSession.delete_all
    @original_resolver = ActionAgent.provider_credentials_resolver
    @original_scope = ActionAgent.agent_scope_resolver
    ActionAgent.provider_credentials_resolver = lambda do |_owner, provider|
      provider == "openai" ? { access_token: "synthetic-fixture-key", api_version: :chat } : {}
    end
    @sandbox = live_sandbox
    @agent = ActionAgent::Agent.create!(
      name: "Orders", provider: "openai", model: "gpt-4o-mini", instructions: "Look orders up.", mcp_servers: [], tools: []
    )
    @evaluation = @agent.evaluations.new(name: "Order lookups", judge_kind: "rules", criteria: [])
    @evaluation.scenarios.build(key: "find_order", prompt: "Where is order A-17?", expectations: { "tools" => [ "lookup_order" ] })
    @evaluation.save!
  end

  def teardown
    ActionAgent.provider_credentials_resolver = @original_resolver
    ActionAgent.agent_scope_resolver = @original_scope
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.execution_enabled = true
  end

  test "an evaluation run against a sandbox calls the runtime's tools, and records which sandbox it used" do
    stub_runtime
    stub_model

    perform_enqueued_jobs do
      post "/activeagents/api/evaluations/#{@evaluation.id}/run", params: { sandbox_id: @sandbox.session_id }, as: :json
    end

    assert_response :success, response.body
    assert_not_includes response.body, RUNTIME_TOKEN
    assert_requested(:post, RUNTIME_URL, headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" }, times: 1) do |request|
      payload = JSON.parse(request.body)
      payload["method"] == "tools/call" && payload.dig("params", "name") == "lookup_order" &&
        payload.dig("params", "arguments") == { "id" => "A-17" }
    end
    # The runtime's tool was offered to the model with the agent's own.
    assert_requested(:post, CHAT_URL, at_least_times: 1) { |request| request.body.include?("lookup_order") }

    assert_equal [], @agent.reload.mcp_servers, "the agent itself is not edited"

    run = @evaluation.evaluation_runs.order(:id).last
    assert run.complete?, run.error_message
    expected = {
      "session_id" => @sandbox.session_id, "server_key" => @sandbox.runtime_server_key,
      "repository" => "acme/shop", "repository_ref" => "experiment"
    }
    assert_equal expected, run.sandbox
    result = run.scenario_results.sole
    assert_equal [ "lookup_order" ], result.tool_calls.map { |call| call["name"] }
    assert result.passed?, result.fault
    agent_run = ActionAgent::AgentRun.find(result.agent_run_id)
    assert_equal @sandbox.runtime_server_key, agent_run.sandbox_server_key

    get "/activeagents/api/evaluations/#{@evaluation.id}/runs/#{run.id}"
    body = JSON.parse(response.body)
    assert_equal expected, body.dig("run", "sandbox")
    assert_equal @sandbox.session_id, body.dig("run", "selection", "sandbox", "session_id")

    get "/activeagents/api/evaluations/#{@evaluation.id}/runs/#{run.id}/report"
    assert_includes response.body, "acme/shop@experiment"

    [ run.attributes.to_json, agent_run.attributes.to_json, response.body ].each do |stored|
      assert_not_includes stored, RUNTIME_TOKEN
    end
  end

  test "a run against a sandbox that stopped before it started fails and says so" do
    post "/activeagents/api/evaluations/#{@evaluation.id}/run", params: { sandbox_id: @sandbox.session_id }, as: :json
    assert_response :success, response.body
    @sandbox.update!(status: :expired)

    # The runner records the failure on the run, then lets the job fail too.
    assert_raises(ArgumentError) { perform_enqueued_jobs }

    run = @evaluation.evaluation_runs.order(:id).last
    assert run.failed?
    assert_match(/no longer running/, run.error_message)
  end

  test "a run is refused for a sandbox that is unknown, not a checkout, or not ready" do
    unknown = SecureRandom.uuid
    browser = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp", status: :ready)
    booting = live_sandbox
    booting.update!(status: :provisioning)

    {
      unknown => /No sandbox #{unknown} of yours/,
      browser.session_id => /playwright_mcp sandbox; only a checkout/,
      booting.session_id => /is provisioning; run against a checkout sandbox once it is ready/
    }.each do |sandbox_id, message|
      assert_no_enqueued_jobs do
        post "/activeagents/api/evaluations/#{@evaluation.id}/run", params: { sandbox_id: sandbox_id }, as: :json
      end
      assert_response :unprocessable_entity
      assert_match message, JSON.parse(response.body)["error"]
    end
    assert_empty @evaluation.evaluation_runs
  end

  test "another owner's sandbox is refused like an unknown one" do
    ActionAgent.user_class = "User"
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @sandbox.update_columns(user_id: owner.id)
    @agent.update_columns(user_id: stranger.id)
    ActionAgent.current_user_resolver = ->(_controller) { stranger }

    post "/activeagents/api/evaluations/#{@evaluation.id}/run", params: { sandbox_id: @sandbox.session_id }, as: :json

    assert_response :unprocessable_entity
    assert_match(/No sandbox #{@sandbox.session_id} of yours/, JSON.parse(response.body)["error"])
    assert_empty @evaluation.evaluation_runs
  end

  test "a sandbox the caller owns but the agent's owner does not is refused" do
    ActionAgent.user_class = "User"
    caller = User.create!(email: "caller-#{SecureRandom.hex(3)}@example.com", name: "Caller", age: 30)
    colleague = User.create!(email: "colleague-#{SecureRandom.hex(3)}@example.com", name: "Colleague", age: 30)
    @sandbox.update_columns(user_id: caller.id)
    @agent.update_columns(user_id: colleague.id)
    # A host that lets a caller reach a colleague's agents.
    ActionAgent.agent_scope_resolver = ->(_owner) { ActionAgent::Agent.all }
    ActionAgent.current_user_resolver = ->(_controller) { caller }

    post "/activeagents/api/evaluations/#{@evaluation.id}/run", params: { sandbox_id: @sandbox.session_id }, as: :json

    assert_response :unprocessable_entity
    assert_match(/does not belong to the owner of Orders/, JSON.parse(response.body)["error"])
  end

  test "a generation-sampling evaluation cannot run against a sandbox" do
    sampling = @agent.evaluations.create!(
      name: "Recorded", judge_kind: "rules", criteria: [ { "key" => "present", "type" => "response_present", "config" => {} } ]
    )

    post "/activeagents/api/evaluations/#{sampling.id}/run", params: { sandbox_id: @sandbox.session_id }, as: :json

    assert_response :unprocessable_entity
    assert_match(/Only a scenario evaluation runs the agent/, JSON.parse(response.body)["error"])
  end

  test "a runner test run against a sandbox reaches its runtime without editing the agent" do
    stub_runtime
    stub_model

    post "/activeagents/api/agents/#{@agent.id}/test", params: { prompt: "Where is order A-17?", sandbox_id: @sandbox.session_id }, as: :json

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal "Order A-17 has shipped.", body["output"]
    assert_equal @sandbox.session_id, body.dig("run", "sandbox_id")
    assert_requested(:post, RUNTIME_URL, headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" }) do |request|
      JSON.parse(request.body)["method"] == "tools/call"
    end
    assert_equal [], @agent.reload.mcp_servers
  end

  test "an execute run records the sandbox, and a client cannot name one through params" do
    post "/activeagents/api/agents/#{@agent.id}/execute", params: { prompt: "Hi", sandbox_id: @sandbox.session_id }, as: :json
    assert_response :accepted, response.body
    run = ActionAgent::AgentRun.find(JSON.parse(response.body).dig("run", "id"))
    assert_equal @sandbox.runtime_server_key, run.sandbox_server_key

    other = live_sandbox
    post "/activeagents/api/agents/#{@agent.id}/execute", params: {
      prompt: "Hi", params: { "_sandbox_server" => other.runtime_server_key, "runtime_sandbox" => other.runtime_server_key }
    }, as: :json
    assert_response :accepted, response.body
    run = ActionAgent::AgentRun.find(JSON.parse(response.body).dig("run", "id"))
    assert_nil run.sandbox_server_key
    assert_not_includes run.input_params.to_json, other.session_id

    post "/activeagents/api/agents/#{@agent.id}/execute", params: { prompt: "Hi", sandbox_id: SecureRandom.uuid }, as: :json
    assert_response :unprocessable_entity
  end

  private

  def live_sandbox
    sandbox = ActionAgent::SandboxSession.new(
      session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/shop", repository_ref: "experiment"
    )
    # The repository check reads a GitHub selection this test has no need of.
    sandbox.save!(validate: false)
    sandbox.mark_ready!(cloud_run_url: "http://127.0.0.1:4100", runtime_mcp_url: RUNTIME_URL, runtime_mcp_token: RUNTIME_TOKEN)
    sandbox
  end

  # The runtime's MCP endpoint, answering only a request with its token.
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
                         inputSchema: { type: "object", properties: { id: { type: "string" } }, required: [ "id" ] } } ] }
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

  # The model: asks for lookup_order, then answers from its result.
  def stub_model
    stub_request(:post, CHAT_URL).to_return do |request|
      messages = JSON.parse(request.body)["messages"]
      message =
        if messages.any? { |entry| entry["role"] == "tool" }
          { role: "assistant", content: "Order A-17 has shipped." }
        else
          { role: "assistant", content: nil, tool_calls: [
            { id: "call_1", type: "function", function: { name: "lookup_order", arguments: { id: "A-17" }.to_json } }
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
