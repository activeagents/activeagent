# frozen_string_literal: true

require "test_helper"

# A dashboard agent that pauses to ask a person, end to end: the run waits
# with its requests stored, an answer through the API resumes the same run
# under the same trace, and the answer reaches the paused tool. The model is
# stubbed on the wire, as Anthropic Messages and as OpenAI Chat Completions.
class InputRequestsExecutionTest < ActionDispatch::IntegrationTest
  ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
  CHAT_URL = "https://api.openai.com/v1/chat/completions"
  SECRET = "sk-live-probe-4f9a2c71d0e8b6"
  PROBE_AGENT = "ActionAgent::SecretProbeAgent"

  # An agent class of the host application's own, run through the dashboard
  # when ActionAgent.run_host_agent_classes is on.
  class HostRefundAgent < ApplicationAgent
    generate_with :anthropic, model: "claude-sonnet-4-5", api_key: "synthetic-anthropic-key"

    class_attribute :refunds, default: []

    REFUND_TOOL = {
      name: "issue_refund", description: "Refund an order",
      parameters: { type: "object", properties: { order_id: { type: "integer" } }, required: [ "order_id" ] }
    }.freeze

    def ask
      prompt(message: "Refund order 7", tools: [ REFUND_TOOL ])
    end

    def issue_refund(order_id:)
      return ActiveAgent::InputRequest.confirm("Refund order #{order_id}?") unless input_answer

      refunds << order_id
      { refunded: order_id }
    end
  end

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
    @original_resolver = ActionAgent.provider_credentials_resolver
    ActionAgent.provider_credentials_resolver = lambda do |_owner, provider|
      case provider
      when "anthropic" then { access_token: "synthetic-anthropic-key" }
      when "openai" then { access_token: "synthetic-openai-key", api_version: :chat }
      else {}
      end
    end
    @bodies = []
  end

  def teardown
    ActionAgent.run_host_agent_classes = false
    HostRefundAgent.refunds = []
    ActionAgent.provider_credentials_resolver = @original_resolver
    ActionAgent::SecretRequests.unregister(PROBE_AGENT)
  end

  # --- Anthropic Messages ---------------------------------------------------

  def tool_use(id, name, input) = { type: "tool_use", id: id, name: name, input: input }

  def text_block(text) = { type: "text", text: text }

  def assistant_message(*content)
    stop_reason = content.any? { |block| block[:type] == "tool_use" } ? "tool_use" : "end_turn"
    { id: "msg_#{SecureRandom.hex(4)}", type: "message", role: "assistant", model: "claude-sonnet-4-5",
      content: content, stop_reason: stop_reason, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 10 } }
  end

  def stub_anthropic(*messages)
    stub_request(:post, ANTHROPIC_URL)
      .with { |request| @bodies << request.body }
      .to_return(*messages.map { |body| { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json } })
  end

  # The tool results the latest request sent back, by tool_use id.
  def anthropic_tool_results
    JSON.parse(@bodies.last)["messages"].flat_map { |turn| Array(turn["content"]) }
      .select { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
      .to_h { |block| [ block["tool_use_id"], block["content"].to_json ] }
  end

  def anthropic_agent(**attributes)
    ActionAgent::Agent.create!(
      { name: "Concierge", provider: "anthropic", model: "claude-sonnet-4-5", instructions: "Help the traveller.", tools: [ "ask" ] }
        .merge(attributes)
    )
  end

  # --- OpenAI Chat Completions ----------------------------------------------

  def completion(tool_calls: nil, content: nil)
    { id: "chatcmpl-#{SecureRandom.hex(4)}", object: "chat.completion", created: 1_761_502_994, model: "gpt-4o-mini",
      choices: [ { index: 0, message: { role: "assistant", content: content, tool_calls: tool_calls }.compact,
                   finish_reason: tool_calls ? "tool_calls" : "stop" } ],
      usage: { prompt_tokens: 20, completion_tokens: 10, total_tokens: 30 } }
  end

  def function_call(id, name, arguments) = { id: id, type: "function", function: { name: name, arguments: arguments.to_json } }

  def stub_chat(*bodies)
    stub_request(:post, CHAT_URL)
      .with { |request| @bodies << request.body }
      .to_return(*bodies.map { |body| { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json } })
  end

  # --- helpers --------------------------------------------------------------

  def run_in_background(agent, prompt)
    run = nil
    perform_enqueued_jobs { run = agent.execute(prompt) }
    run.reload
  end

  def answer(request, value)
    perform_enqueued_jobs do
      post "/activeagents/api/input_requests/#{request.id}/answer", params: { answer: value }, as: :json
    end
    assert_response :success, response.body
  end

  def decline(request)
    perform_enqueued_jobs { post "/activeagents/api/input_requests/#{request.id}/decline", as: :json }
    assert_response :success, response.body
  end

  def user_messages_for(run)
    ActionAgent::AgentMessage.where(role: "user").select { |message| message.provenance&.dig("trace_id") == run.trace_id }
  end

  def event_statuses(run, label)
    Array(run.logs).select { |event| event["label"] == label }.map { |event| event["status"] }
  end

  # --- pause and resume -----------------------------------------------------

  test "an ask_user call pauses the run, and the answer resumes it under the same trace" do
    stub_anthropic(
      assistant_message(text_block("Let me check."), tool_use("toolu_1", "ask_user", { question: "Which city?" })),
      assistant_message(text_block("Lisbon it is."))
    )
    run = run_in_background(anthropic_agent, "Plan a weekend away")

    assert run.awaiting_input?, run.error_message
    assert_nil run.completed_at
    assert_nil run.output
    request = run.input_requests.sole
    assert_equal [ "text", "Which city?", "ask_user", "toolu_1", "pending" ],
      [ request.kind, request.prompt, request.tool_name, request.tool_call_id, request.status ]
    assert_equal %w[started awaiting], event_statuses(run, "ask_user")
    assert_not_includes run.logs.filter_map { |entry| entry["message"] }, "Execution completed successfully"
    assert_equal 1, ActionAgent::TelemetryTrace.where(trace_id: run.trace_id).count
    assert_requested :post, ANTHROPIC_URL, times: 1

    answer(request, "Lisbon")

    run.reload
    assert run.complete?, run.error_message
    assert_equal "Lisbon it is.", run.output
    assert_requested :post, ANTHROPIC_URL, times: 2
    assert_includes anthropic_tool_results.fetch("toolu_1"), "Lisbon"
    assert_equal [ "Plan a weekend away" ], user_messages_for(run).map(&:content)
    conversation = ActionAgent::AgentMessage.order(:id).map { |row| [ row.role, row.content.to_s ] }
    assert_equal [ %w[user tool assistant], "Lisbon it is." ], [ conversation.map(&:first), conversation.last.last ],
      "the paused turn is not persisted; the finished run's exchange is, once"
    assert_includes conversation.second.last, "Lisbon"
    assert_equal %w[started awaiting started done], event_statuses(run, "ask_user")
    assert_equal [ "ask_user" ], run.output_metadata["tool_calls"]
    assert_equal 40, run.input_tokens

    trace = ActionAgent::TelemetryTrace.find_by!(trace_id: run.trace_id)
    assert_equal 1, trace.spans.count { |span| span["parent_span_id"].nil? }, "the resumed segment hangs off the run's root"
    assert_equal 2, trace.spans.count { |span| span["type"] == "llm" }, "both segments' model calls are in the trace"
    assert_equal 40, trace.total_input_tokens
  end

  test "the same pause and resume works on an OpenAI Chat-based provider" do
    stub_chat(
      completion(tool_calls: [ function_call("call_1", "ask_user", { question: "Which city?" }) ]),
      completion(content: "Lisbon it is.")
    )
    agent = anthropic_agent(provider: "openai", model: "gpt-4o-mini")
    run = run_in_background(agent, "Plan a weekend away")
    assert run.awaiting_input?, run.error_message

    answer(run.input_requests.sole, "Lisbon")

    run.reload
    assert run.complete?, run.error_message
    assert_equal "Lisbon it is.", run.output
    messages = JSON.parse(@bodies.last)["messages"]
    tool_messages = messages.select { |item| item["role"] == "tool" }
    assert_equal [ "call_1" ], tool_messages.map { |item| item["tool_call_id"] }
    assert_includes tool_messages.sole["content"], "Lisbon"
    assert_equal 1, messages.count { |item| %w[developer system].include?(item["role"]) }, "instructions are sent once"
    assert_equal 1, messages.count { |item| item["role"] == "user" }
    assert_equal [ "Plan a weekend away" ], user_messages_for(run).map(&:content)
  end

  test "two parallel questions pause together, and the run resumes once both are answered" do
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "ask_user", { question: "Which city?" }),
              tool_use("toolu_2", "ask_user", { question: "Which class?", options: %w[economy business] })),
      assistant_message(text_block("Booked."))
    )
    run = run_in_background(anthropic_agent, "Book a trip")
    city, cabin = run.input_requests.order(:id).to_a
    assert_equal %w[text choice], [ city.kind, cabin.kind ]
    assert_equal %w[economy business], cabin.options
    assert_equal city.pause_key, cabin.pause_key

    answer(city, "Lisbon")
    assert run.reload.awaiting_input?
    assert_requested :post, ANTHROPIC_URL, times: 1

    answer(cabin, "business")
    assert run.reload.complete?, run.error_message
    assert_requested :post, ANTHROPIC_URL, times: 2
    results = anthropic_tool_results
    assert_includes results.fetch("toolu_1"), "Lisbon"
    assert_includes results.fetch("toolu_2"), "business"
  end

  test "two resume jobs for the same settled pause resume it once, and each call runs once" do
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "ask_user", { question: "Which city?" }), tool_use("toolu_2", "ask_user", { question: "When?" })),
      assistant_message(text_block("Booked."))
    )
    run = run_in_background(anthropic_agent, "Book a trip")
    city, date = run.input_requests.order(:id).to_a
    city.update!(status: :answered, answer: "Lisbon")
    date.update!(status: :answered, answer: "Friday")

    ActionAgent::AgentResumeJob.perform_now(city.id)
    ActionAgent::AgentResumeJob.perform_now(date.id)

    assert run.reload.complete?, run.error_message
    assert_requested :post, ANTHROPIC_URL, times: 2
    assert_equal 2, event_statuses(run, "ask_user").count("done"), "each paused call ran once on resume"
  end

  test "a resume job for an earlier pause leaves a run that paused again alone" do
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "ask_user", { question: "Which city?" })),
      assistant_message(tool_use("toolu_2", "ask_user", { question: "Which weekend?" })),
      assistant_message(text_block("Lisbon, the first weekend of May."))
    )
    run = run_in_background(anthropic_agent, "Plan a weekend away")
    city = run.input_requests.sole
    answer(city, "Lisbon")
    assert run.reload.awaiting_input?, run.error_message
    weekend = run.input_requests.pending.sole

    ActionAgent::AgentResumeJob.perform_now(city.id)

    assert run.reload.awaiting_input?
    assert weekend.reload.pending?
    assert_requested :post, ANTHROPIC_URL, times: 2

    answer(weekend, "The first weekend of May")
    assert run.reload.complete?, run.error_message
    assert_equal "Lisbon, the first weekend of May.", run.output
    assert_requested :post, ANTHROPIC_URL, times: 3
  end

  test "an agent run from its host class pauses and resumes the same way" do
    ActionAgent.run_host_agent_classes = true
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "issue_refund", { order_id: 7 })),
      assistant_message(text_block("Refunded."))
    )
    agent = anthropic_agent(name: "Refunds", agent_class_name: "InputRequestsExecutionTest::HostRefundAgent", tools: [])
    run = run_in_background(agent, "Refund order 7")

    assert run.awaiting_input?, run.error_message
    request = run.input_requests.sole
    assert_equal [ "confirm", "Refund order 7?", "issue_refund" ], [ request.kind, request.prompt, request.tool_name ]
    assert_empty HostRefundAgent.refunds

    answer(request, true)

    assert run.reload.complete?, run.error_message
    assert_equal "Refunded.", run.output
    assert_equal [ 7 ], HostRefundAgent.refunds
  end

  # --- approvals ------------------------------------------------------------

  def gated_agent
    anthropic_agent(tools: [ "code" ], approval_required_tools: [ "calculate" ])
  end

  def calculate_turns
    [ assistant_message(tool_use("toolu_1", "calculate", { expression: "6 * 7" })), assistant_message(text_block("It is 42.")) ]
  end

  def counting_calculate(calls)
    lambda do |expression:|
      calls << expression
      { expression: expression, result: 42 }
    end
  end

  test "a tool on the approval list waits for approval, and runs once when approved" do
    stub_anthropic(*calculate_turns)
    calls = []

    ActionAgent::AgentToolbox.stub(:calculate, counting_calculate(calls)) do
      run = run_in_background(gated_agent, "What is six times seven?")
      request = run.input_requests.sole
      assert_equal [ "confirm", "calculate", { "expression" => "6 * 7" } ], [ request.kind, request.tool_name, request.arguments ]
      assert_empty calls, "the tool must not run before it is approved"

      answer(request, true)

      assert run.reload.complete?, run.error_message
      assert_equal [ "6 * 7" ], calls
      assert_includes anthropic_tool_results.fetch("toolu_1"), "42"
    end
  end

  test "a declined tool never runs, and the model reads an error" do
    stub_anthropic(*calculate_turns)
    calls = []

    ActionAgent::AgentToolbox.stub(:calculate, counting_calculate(calls)) do
      run = run_in_background(gated_agent, "What is six times seven?")

      decline(run.input_requests.sole)

      assert run.reload.complete?, run.error_message
      assert_empty calls
      assert_includes anthropic_tool_results.fetch("toolu_1"), "declined by user"
    end
  end

  test "answering false declines a gated call, so the tool never runs" do
    stub_anthropic(*calculate_turns)
    calls = []

    ActionAgent::AgentToolbox.stub(:calculate, counting_calculate(calls)) do
      run = run_in_background(gated_agent, "What is six times seven?")
      request = run.input_requests.sole

      answer(request, false)

      assert request.reload.declined?
      assert run.reload.complete?, run.error_message
      assert_empty calls
      assert_includes anthropic_tool_results.fetch("toolu_1"), "declined by user"
    end
  end

  test "request_approval asks to approve what the model describes" do
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "request_approval", { action: "Email the itinerary to the whole team" })),
      assistant_message(text_block("Sent."))
    )
    run = run_in_background(anthropic_agent, "Share the plan")
    request = run.input_requests.sole
    assert_equal [ "confirm", "Email the itinerary to the whole team" ], [ request.kind, request.prompt ]
    assert_equal({ "action" => "Email the itinerary to the whole team" }, request.arguments)

    answer(request, true)

    assert run.reload.complete?, run.error_message
    assert_includes anthropic_tool_results.fetch("toolu_1"), "approved"
  end

  # --- secrets --------------------------------------------------------------

  test "request_secret is offered only to an agent with a registered handler" do
    assert_not_includes ActionAgent::Agent.available_tools, "request_secret"
    assert_empty ActionAgent::AgentToolbox.definitions_for(%w[request_secret ask]).select { |tool| tool[:name] == "request_secret" }

    stub_anthropic(assistant_message(text_block("Hello.")))
    run = run_in_background(anthropic_agent(tools: %w[ask request_secret]), "Hi")
    assert run.complete?, run.error_message
    offered = JSON.parse(@bodies.last)["tools"].map { |tool| tool["name"] }
    assert_equal %w[ask_user request_approval], offered
  end

  test "a secret answer reaches its handler and appears in no record, response, log or job argument" do
    received = []
    ActionAgent::SecretRequests.register(PROBE_AGENT) { |run:, name:, value:| received << [ run.id, name, value ] }
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "request_secret", { name: "PROBE_TOKEN", prompt: "Paste the probe token" })),
      assistant_message(text_block("Stored."))
    )
    agent = anthropic_agent(name: "Secret Probe", agent_class_name: PROBE_AGENT, tools: [])
    run = run_in_background(agent, "Connect the probe")
    assert_includes JSON.parse(@bodies.first)["tools"].map { |tool| tool["name"] }, "request_secret"
    request = run.input_requests.sole
    assert_equal "secret", request.kind

    logged = []
    subscriber = ActiveSupport::Notifications.subscribe("start_processing.action_controller") { |*, payload| logged << payload[:params] }
    assert_enqueued_with(job: ActionAgent::AgentResumeJob, args: [ request.id ]) do
      post "/activeagents/api/input_requests/#{request.id}/answer", params: { answer: SECRET }, as: :json
    end
    responses = [ response.body ]
    jobs = enqueued_jobs.map { |job| job[:args] }
    perform_enqueued_jobs

    run.reload
    assert run.complete?, run.error_message
    assert_equal [ [ run.id, "PROBE_TOKEN", SECRET ] ], received
    assert_includes anthropic_tool_results.fetch("toolu_1"), "provided"
    assert_nil request.reload.answer, "the secret is not kept once its tool received it"

    get "/activeagents/api/input_requests", params: { status: "all" }
    responses << response.body
    get "/activeagents/api/runs/#{run.id}"
    responses << response.body
    key = ActionAgent::ApiKey.create!(name: "Harness")
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "input_requests_list", arguments: {} } }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.token}" }
    responses << response.body

    recorded = {
      "provider request bodies" => @bodies,
      "trace spans" => ActionAgent::TelemetryTrace.where(trace_id: run.trace_id).pluck(:spans, :error_message),
      "run logs and metadata" => [ run.logs, run.output_metadata, run.output, run.error_message ],
      "agent messages" => ActionAgent::AgentMessage.all.map(&:attributes),
      "job arguments" => jobs,
      "API and MCP responses" => responses,
      "request log" => logged
    }
    recorded.each do |where, value|
      assert_not_includes value.to_json, SECRET, "the secret leaked into the #{where}"
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "a handler error that quotes the secret is scrubbed before anything records it" do
    ActionAgent::SecretRequests.register(PROBE_AGENT) { |value:, **| raise ArgumentError, "rejected token #{value}" }
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "request_secret", { name: "PROBE_TOKEN", prompt: "Paste the probe token" })),
      assistant_message(text_block("That token was rejected."))
    )
    run = run_in_background(anthropic_agent(name: "Secret Probe", agent_class_name: PROBE_AGENT, tools: []), "Connect the probe")

    answer(run.input_requests.sole, SECRET)

    run.reload
    assert run.complete?, run.error_message
    assert_includes anthropic_tool_results.fetch("toolu_1"), "rejected token [FILTERED]"
    assert_includes run.logs.to_json, "rejected token [FILTERED]"
    spans = ActionAgent::TelemetryTrace.find_by!(trace_id: run.trace_id).spans
    assert_includes spans.to_json, "rejected token [FILTERED]"
    [ @bodies, spans, run.logs, run.output_metadata, ActionAgent::AgentMessage.all.map(&:attributes) ].each do |recorded|
      assert_not_includes recorded.to_json, SECRET
    end
  end

  # --- synchronous callers --------------------------------------------------

  test "call_agent refuses a called agent that pauses, and cancels its requests" do
    helper = anthropic_agent(name: "Helper", slug: "helper")
    caller_agent = anthropic_agent(name: "Lead", slug: "lead", tools: [ "agents" ])
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "call_agent", { slug: "helper", message: "Find a hotel" })),
      assistant_message(tool_use("toolu_9", "ask_user", { question: "Which neighbourhood?" })),
      assistant_message(text_block("I could not finish that."))
    )

    run = caller_agent.test_execute("Plan the trip")

    assert run.complete?, run.error_message
    sub_run = helper.agent_runs.sole
    assert sub_run.cancelled?
    assert sub_run.input_requests.all?(&:cancelled?)
    result = anthropic_tool_results.fetch("toolu_1")
    assert_includes result, "input_required"
    assert_includes result, "Which neighbourhood?"
  end

  test "an MCP run of an agent that pauses returns its run id, status and request ids" do
    agent = anthropic_agent(slug: "concierge", status: :active)
    key = ActionAgent::ApiKey.create!(name: "Harness")
    stub_anthropic(assistant_message(tool_use("toolu_1", "ask_user", { question: "Which city?" })))

    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "run_concierge", arguments: { message: "Plan a trip" } } }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.token}" }

    result = JSON.parse(response.body)["result"]
    run = agent.agent_runs.sole
    assert_equal(
      { "run_id" => run.id, "trace_id" => run.trace_id, "status" => "awaiting_input", "input_request_ids" => run.input_requests.pluck(:id) },
      result["structuredContent"]
    )
    assert_match(/Which city\?/, result.dig("content", 0, "text"))
  end

  test "an evaluation replay of an agent that pauses records an error and cancels the run" do
    agent = anthropic_agent
    evaluation = agent.evaluations.new(name: "Trips", judge_kind: "rules", criteria: [])
    evaluation.scenarios.build(key: "trip_1", prompt: "Plan a weekend away")
    evaluation.save!
    stub_anthropic(assistant_message(tool_use("toolu_1", "ask_user", { question: "Which city?" })))

    evaluation.run!(keys: [ "trip_1" ])

    result = evaluation.evaluation_runs.sole.scenario_results.sole
    assert_equal "paused for input", result.error_message
    agent_run = ActionAgent::AgentRun.find(result.agent_run_id)
    assert agent_run.cancelled?
    assert agent_run.input_requests.all?(&:cancelled?)
  end
end
