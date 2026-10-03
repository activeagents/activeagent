# frozen_string_literal: true

require "test_helper"

# The timeline of a conversation, a run, an evaluation scenario's replay or a
# recording: message, llm, tool and browser lanes on one time axis, derived
# when read.
class SessionTimelineTest < ActionDispatch::IntegrationTest
  T0 = Time.utc(2026, 9, 1, 12, 0, 0)

  def setup
    [
      ActionAgent::RecordingEvent, ActionAgent::RecordingAction, ActionAgent::SessionRecording,
      ActionAgent::EvaluationScenarioResult, ActionAgent::EvaluationScenario, ActionAgent::EvaluationRun,
      ActionAgent::Evaluation, ActionAgent::AgentMessage, ActionAgent::AgentGeneration, ActionAgent::AgentContext,
      ActionAgent::TelemetryTrace, ActionAgent::AgentRun, ActionAgent::Agent, User
    ].each(&:delete_all)

    @agent = ActionAgent::Agent.create!(name: "Support Bot", provider: "mock", model: "mock")
    @context = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "SupportBot", action_name: "ask")
    @traced_run = traced_run(@context)
  end

  def teardown
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
  end

  # A run whose trace is stored, with a browser_type call in it.
  def traced_run(context)
    run = @agent.agent_runs.create!(trace_id: "trace-traced", status: :complete, started_at: T0, completed_at: T0 + 5)
    add_message(context, "user", "Sign me in", at: T0 + 0.1, trace_id: run.trace_id)
    add_message(context, "assistant", nil, at: T0 + 1.0,
      metadata: { "tool_calls" => [ { "id" => "call_1", "name" => "browser_type", "arguments" => { "ref" => "e1", "text" => "hunter2secret" } } ] })
    add_message(context, "tool", "Typed hunter2secret into the field", at: T0 + 1.6,
      tool_name: "browser_type", tool_call_id: "call_1", tool_arguments: { "ref" => "e1", "text" => "hunter2secret" })
    add_message(context, "assistant", "You are signed in.", at: T0 + 3.0)
    context.generations.create!(content: "You are signed in.", model: "mock-model", trace_id: run.trace_id,
      duration_seconds: 0.8, created_at: T0 + 1.0)
    ActionAgent::TelemetryTrace.create!(
      trace_id: run.trace_id, timestamp: T0, service_name: "activeagents-platform",
      spans: [
        span("root", nil, "SupportBot.prompt", "root", T0, T0 + 4),
        span("llm-1", "root", "llm.generate", "llm", T0 + 0.2, T0 + 1.0, "llm.model" => "mock-model"),
        span("tool-1", "root", "tool.browser_type", "tool", T0 + 1.1, T0 + 1.5,
          "tool.name" => "browser_type",
          "tool.input.args" => { ref: "e1", text: "hunter2secret" }.to_json,
          "tool.output.result" => "await page.fill('hunter2secret')")
      ]
    )
    run
  end

  # A run with no stored trace, whose lanes come from its run log.
  def logged_run(context)
    run = @agent.agent_runs.create!(trace_id: "trace-logged", status: :complete, started_at: T0 + 10, completed_at: T0 + 14,
      logs: [
        log("1", "llm", "mock/mock generating", "started", T0 + 10.2),
        log("1", "llm", "mock/mock generating", "done", T0 + 11.0, duration_ms: 800),
        log("2", "tool", "browser_type", "started", T0 + 11.1, detail: { ref: "e2", text: "s3cretpass" }.to_json),
        log("2", "tool", "browser_type", "done", T0 + 11.4, duration_ms: 300, detail: "typed s3cretpass")
      ])
    add_message(context, "user", "Try again", at: T0 + 10.1, trace_id: run.trace_id)
    add_message(context, "assistant", "Done.", at: T0 + 12.0)
    context.generations.create!(content: "Done.", model: "mock-model", trace_id: run.trace_id, duration_seconds: 0.8, created_at: T0 + 11)
    run
  end

  def add_message(context, role, content, at:, trace_id: nil, **attributes)
    context.messages.create!(role: role, content: content, created_at: at,
      provenance: trace_id ? { "trace_id" => trace_id } : {}, **attributes)
  end

  def span(id, parent, name, type, started, finished, attributes = {})
    {
      "span_id" => id, "parent_span_id" => parent, "name" => name, "type" => type,
      "start_time" => started.iso8601(6), "end_time" => finished.iso8601(6),
      "duration_ms" => ((finished - started) * 1000).round(3), "status" => "OK", "attributes" => attributes
    }
  end

  def log(eid, kind, label, status, at, duration_ms: nil, detail: nil)
    { "eid" => eid, "kind" => kind, "label" => label, "status" => status, "at" => at.iso8601(3),
      "duration_ms" => duration_ms, "detail" => detail }.compact
  end

  def timeline(path)
    get "/activeagents/api/#{path}"
    assert_response :success
    response.parsed_body["timeline"]
  end

  def starts(lane)
    lane.map { |entry| entry["start"] }
  end

  # --- sessions with no recording -----------------------------------------

  test "a conversation's timeline has its message, llm and tool lanes in time order" do
    lanes = timeline("sessions/context/#{@context.id}/timeline")["lanes"]

    assert_equal %w[user assistant tool assistant], lanes["message"].map { |entry| entry["role"] }
    assert_equal [ "span-llm-1" ], lanes["llm"].map { |entry| entry["id"] }
    assert_equal [ "span-tool-1" ], lanes["tool"].map { |entry| entry["id"] }
    lanes.each_value { |lane| assert_equal starts(lane).sort, starts(lane) }
    assert_equal "trace-traced", lanes["tool"].sole["trace_id"]
    assert_equal 400.0, lanes["tool"].sole["duration_ms"]
    assert_empty lanes["browser"]
  end

  test "every entry has an absolute start, a duration and a trace id, nil when unknown" do
    recording = ActionAgent::SessionRecording.start!(agent_context: @context, source: "dashboard")
    recording.record_action!(action_type: "click", selector: "#sign-in")
    add_message(@context, "user", "An untraced note", at: T0 - 1)

    lanes = timeline("sessions/context/#{@context.id}/timeline")["lanes"]

    assert_equal %w[browser llm message tool], lanes.reject { |_, lane| lane.empty? }.keys.sort
    lanes.values.flatten.each do |entry|
      assert Time.iso8601(entry["start"]), entry["id"]
      assert_kind_of Numeric, entry["duration_ms"], entry["id"]
      assert entry.key?("trace_id"), entry["id"]
    end
    assert_nil lanes["message"].first["trace_id"], "the note predates every run"
    assert_nil lanes["browser"].sole["trace_id"]
  end

  test "a browser tool's typed text is masked in every lane" do
    body = timeline("sessions/context/#{@context.id}/timeline").to_json

    assert_not_includes body, "hunter2secret"
    tool = JSON.parse(body).dig("lanes", "tool").sole
    assert_equal "[REDACTED]", JSON.parse(tool["arguments"])["text"]
    assert_equal "await page.fill('[REDACTED]')", tool["result"]
  end

  test "a run without a stored trace takes its lanes from its run log, and only its own messages" do
    run = logged_run(@context)

    session = timeline("sessions/run/#{run.id}/timeline")
    lanes = session["lanes"]

    assert_equal %w[Try\ again Done.], lanes["message"].map { |entry| entry["content"] }
    assert_equal [ "log-1" ], lanes["llm"].map { |entry| entry["id"] }
    assert_equal 800, lanes["llm"].sole["duration_ms"]
    tool = lanes["tool"].sole
    assert_equal "browser_type", tool["name"]
    assert_equal "typed [REDACTED]", tool["detail"]
    assert_equal [ run.id ], session.dig("session", "agent_run_ids")
    assert_equal [ @context.id ], session.dig("session", "agent_context_ids")
    assert_not_includes session.to_json, "s3cretpass"
  end

  test "a conversation whose generations have no run or trace takes its llm lane from them" do
    context = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "SupportBot", action_name: "summarize")
    add_message(context, "user", "Summarize", at: T0 + 20, trace_id: "trace-bare")
    context.generations.create!(content: "Summary", model: "mock-model", trace_id: "trace-bare", duration_seconds: 2.0, created_at: T0 + 23)

    llm = timeline("sessions/context/#{context.id}/timeline").dig("lanes", "llm").sole

    assert_equal (T0 + 21).iso8601(3), llm["start"]
    assert_equal 2000, llm["duration_ms"]
    assert_equal "trace-bare", llm["trace_id"]
  end

  test "an evaluation scenario's timeline is its replay run's" do
    evaluation = ActionAgent::Evaluation.create!(agent: @agent, name: "Sign in", criteria: [ { "key" => "present", "type" => "response_present" } ])
    scenario = evaluation.scenarios.create!(key: "sign_in", prompt: "Sign me in")
    result = evaluation.evaluation_runs.create!(status: :complete)
      .scenario_results.create!(scenario: scenario, agent_run: @traced_run, provider: "mock", model: "mock-model", status: :passed)

    session = timeline("sessions/scenario_result/#{result.id}/timeline")

    assert_equal [ @traced_run.id ], session.dig("session", "agent_run_ids")
    assert_equal [ "span-llm-1" ], session.dig("lanes", "llm").map { |entry| entry["id"] }
  end

  # --- recordings ---------------------------------------------------------

  test "a recording's timeline merges its browser lane with its run's lanes, and follows no id in a payload" do
    other_run = logged_run(@context)
    recording = ActionAgent::SessionRecording.start!(agent_run: @traced_run, source: "agent")
    recording.record_server_event!(kind: "action", started_at: T0 + 1.1, finished_at: T0 + 1.5, data: {
      "tool_name" => "browser_type", "parameters" => { "ref" => "e1", "text" => "[REDACTED]" },
      "trace_id" => other_run.trace_id, "agent_run_id" => other_run.id, "agent_context_id" => @context.id + 1
    })
    rrweb = recording.recording_events.new(kind: "rrweb")
    rrweb.events = [ { "at" => ActionAgent::RecordingEvent.milliseconds(T0 + 0.5), "data" => { "type" => 2 } } ]
    rrweb.save!

    session = timeline("session_recordings/#{recording.id}/timeline")

    assert_equal "recording", session.dig("session", "kind")
    assert_equal [ @traced_run.id ], session.dig("session", "agent_run_ids")
    assert_equal [ "trace-traced" ], session.dig("session", "trace_ids")
    assert_equal [ "action" ], session.dig("lanes", "browser").map { |entry| entry["kind"] }, "rrweb is read from the events endpoint"
    assert_not session.dig("lanes", "llm").any? { |entry| entry["trace_id"] == other_run.trace_id }
    assert_equal 1, session["recordings"].sole.dig("rrweb", "event_count")
  end

  test "a conversation's timeline adds the browser lane of the recordings linked to it" do
    recording = ActionAgent::SessionRecording.start!(agent_context: @context, source: "dashboard")
    recording.record_action!(action_type: "click", selector: "#sign-in")

    lanes = timeline("sessions/context/#{@context.id}/timeline")["lanes"]

    assert_equal [ "click" ], lanes["browser"].map { |entry| entry.dig("data", "action_type") }
  end

  test "a timeline carries no cookies or web storage" do
    recording = ActionAgent::SessionRecording.start!(agent_run: @traced_run, source: "agent")
    recording.update!(metadata: recording.metadata.merge("handoff_state" => { "cookies" => [ { "value" => "cookie-sekrit" } ] }))
    recording.record_action!(action_type: "navigate", value: "https://example.com/", metadata: {
      "url" => "https://example.com/", "cookies" => [ { "value" => "cookie-sekrit" } ],
      "local_storage" => { "token" => "lst-sekrit" }, "session_storage" => { "csrf" => "sst-sekrit" }
    })
    recording.record_server_event!(kind: "action", started_at: T0 + 2, data: { "tool_name" => "browser_evaluate",
      "parameters" => { "local_storage" => { "token" => "lst-sekrit" } } })

    body = timeline("session_recordings/#{recording.id}/timeline").to_json

    %w[cookies local_storage session_storage cookie-sekrit lst-sekrit sst-sekrit].each { |text| assert_not_includes body, text }
    assert_includes body, "https://example.com/"
  end

  test "a long recording fills the browser lane from its earliest rows without decoding the rest" do
    recording = ActionAgent::SessionRecording.start!(agent_run: @traced_run, source: "agent")
    add_console_row(recording, [ T0, T0 + 1.day ])
    rows = 300
    rows.times do |row|
      add_console_row(recording, (0...10).map { |event| T0 + 1 + (row * 10) + event })
    end
    limit = ActionAgent::SessionTimeline::LANE_LIMIT
    loaded = 0
    counter = ->(*, payload) { loaded += payload[:record_count] if payload[:class_name] == "ActionAgent::RecordingEvent" }

    session = ActiveSupport::Notifications.subscribed(counter, "instantiation.active_record") do
      timeline("session_recordings/#{recording.id}/timeline")
    end

    browser = session.dig("lanes", "browser")
    assert session.dig("session", "truncated")
    assert_equal limit, browser.size
    assert_equal (T0 + (limit - 1)).iso8601(3), browser.last["start"], "the lane holds the earliest events"
    assert_not_includes starts(browser), (T0 + 1.day).iso8601(3)
    assert_operator loaded, :<, rows, "rows past the lane's end are not loaded"
  end

  # A console row of one event at each of +times+.
  def add_console_row(recording, times)
    row = recording.recording_events.new(kind: "console")
    row.events = times.map { |time| { "at" => ActionAgent::RecordingEvent.milliseconds(time), "data" => { "message" => "line" } } }
    row.save!
  end

  test "the events endpoint returns no cookies or web storage from events other than rrweb" do
    recording = ActionAgent::SessionRecording.start!(agent_run: @traced_run, source: "agent")
    recording.record_server_event!(kind: "action", started_at: T0 + 2, data: { "tool_name" => "browser_evaluate",
      "parameters" => { "cookies" => [ { "value" => "cookie-sekrit" } ], "local_storage" => { "token" => "lst-sekrit" } } })

    get "/activeagents/api/session_recordings/#{recording.id}/events", params: { kind: "action" }

    assert_response :success
    assert_equal "browser_evaluate", response.parsed_body["events"].sole["events"].sole.dig("data", "tool_name")
    %w[cookies local_storage cookie-sekrit lst-sekrit].each { |text| assert_not_includes response.body, text }
  end

  test "a recording with no run or conversation has only its browser lane" do
    recording = ActionAgent::SessionRecording.start_user_session!(page_url: "https://example.com/")
    recording.record_action!(action_type: "handoff", value: "User took over")

    session = timeline("session_recordings/#{recording.id}/timeline")

    assert_equal [ "handoff" ], session.dig("lanes", "browser").map { |entry| entry.dig("data", "action_type") }
    assert_empty session.dig("lanes", "llm")
    assert_empty session.dig("session", "agent_run_ids")
  end

  # --- ownership ----------------------------------------------------------

  test "a caller who does not own the session gets 404" do
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    ActionAgent.user_class = "User"
    @agent.update!(user_id: owner.id)
    recording = ActionAgent::SessionRecording.start!(agent_run: @traced_run, source: "agent")
    assert_equal owner.id, recording.user_id

    ActionAgent.current_user_resolver = ->(_controller) { stranger }
    [
      "sessions/context/#{@context.id}/timeline",
      "sessions/run/#{@traced_run.id}/timeline",
      "session_recordings/#{recording.id}/timeline",
      "session_recordings/#{recording.id}/events"
    ].each do |path|
      get "/activeagents/api/#{path}"
      assert_response :not_found, path
    end

    ActionAgent.current_user_resolver = ->(_controller) { owner }
    get "/activeagents/api/sessions/run/#{@traced_run.id}/timeline"
    assert_response :success
  end

  test "a recording the caller can open does not reach a run of someone else's" do
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    ActionAgent.user_class = "User"
    @agent.update!(user_id: owner.id)
    recording = ActionAgent::SessionRecording.start!(agent_run: @traced_run, source: "agent", owner: stranger)

    ActionAgent.current_user_resolver = ->(_controller) { stranger }
    session = timeline("session_recordings/#{recording.id}/timeline")

    assert_empty session.dig("session", "agent_run_ids")
    assert_empty session.dig("lanes", "message")
    assert_empty session.dig("lanes", "llm")
  end
end
