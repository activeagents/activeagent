# frozen_string_literal: true

require "test_helper"

# GET /api/sessions: the conversations, evaluation replays and browser
# recordings a caller can replay, newest first, filtered on the server.
class SessionIndexTest < ActionDispatch::IntegrationTest
  T0 = Time.utc(2026, 9, 1, 12, 0, 0)

  def setup
    [
      ActionAgent::RecordingEvent, ActionAgent::RecordingAction, ActionAgent::SessionRecording,
      ActionAgent::EvaluationScenarioResult, ActionAgent::EvaluationScenario, ActionAgent::EvaluationRun,
      ActionAgent::Evaluation, ActionAgent::AgentMessage, ActionAgent::AgentGeneration, ActionAgent::AgentContext,
      ActionAgent::AgentRun, ActionAgent::Agent, User
    ].each(&:delete_all)

    @agent = ActionAgent::Agent.create!(name: "Support Bot", provider: "mock", model: "mock")
    @other_agent = ActionAgent::Agent.create!(name: "Billing Bot", provider: "mock", model: "mock")
  end

  def teardown
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
  end

  # A conversation of +agent+ with one run that wrote a generation to it.
  def conversation(agent: @agent, at: T0, status: :complete, action: "ask", input_params: {})
    context = ActionAgent::AgentContext.create!(contextable: agent, agent_name: "SupportBot", action_name: action,
      created_at: at, updated_at: at)
    run = agent.agent_runs.create!(status: status, started_at: at, input_params: input_params)
    context.messages.create!(role: "user", content: "Where is my order?", created_at: at, provenance: { "trace_id" => run.trace_id })
    context.generations.create!(content: "On its way.", model: "mock-model", trace_id: run.trace_id, created_at: at)
    context.update_columns(updated_at: at)
    [ context, run ]
  end

  # An evaluation replay of +agent+, whose run wrote to a conversation of its
  # own unless +context+ is given.
  def replay(agent: @agent, at: T0, status: :passed, context: nil)
    context ||= ActionAgent::AgentContext.create!(contextable: agent, agent_name: "SupportBot", action_name: "replay",
      created_at: at, updated_at: at)
    run = agent.agent_runs.create!(status: :complete, started_at: at)
    context.generations.create!(content: "Answer", model: "mock-model", trace_id: run.trace_id, created_at: at)
    context.update_columns(updated_at: at)
    evaluation = ActionAgent::Evaluation.create!(agent: agent, name: "Orders #{SecureRandom.hex(3)}", criteria: [ { "key" => "present", "type" => "response_present" } ])
    scenario = evaluation.scenarios.create!(key: "order_status", prompt: "Where is order 7?")
    result = evaluation.evaluation_runs.create!(status: :complete).scenario_results.create!(
      scenario: scenario, agent_run: run, provider: "mock", model: "mock-model", status: status, created_at: at
    )
    [ result, run, context ]
  end

  def recording(at: T0, **attributes)
    recording = ActionAgent::SessionRecording.start!(**{ source: "agent" }.merge(attributes))
    recording.update_columns(created_at: at)
    recording
  end

  def sessions(**params)
    get "/activeagents/api/sessions", params: params
    assert_response :success
    response.parsed_body
  end

  def listed(**params)
    sessions(**params)["sessions"].map { |row| [ row["kind"], row["id"] ] }
  end

  test "with no sessions the index is empty" do
    body = sessions

    assert_equal [], body["sessions"]
    assert_equal 0, body["total"]
    assert_equal false, body["has_more"]
    assert_nil body["next_before"]
  end

  test "lists conversations, evaluation replays and lone browser recordings, newest first" do
    context, run = conversation(at: T0)
    result, replay_run, = replay(at: T0 + 60)
    lone = recording(agent_run: run, at: T0 + 120)
    recording(agent_run: replay_run, at: T0 + 130)
    recording(agent_context: context, source: "dashboard", at: T0 + 140)

    body = sessions

    assert_equal [ [ "recording", lone.id ], [ "scenario_result", result.id ], [ "context", context.id ] ],
      body["sessions"].map { |row| [ row["kind"], row["id"] ] }
    assert_equal 3, body["total"]
    assert_equal %w[agent evaluation dashboard], body["sessions"].map { |row| row["source"] }
    conversation_row = body["sessions"].last
    assert_equal "SupportBot#ask", conversation_row["title"]
    assert_equal "Where is my order?", conversation_row["preview"]
    assert_equal 1, conversation_row["recording_count"]
    assert_equal({ "id" => @agent.id, "name" => "Support Bot", "slug" => @agent.slug }, conversation_row["agent"])
    replay_row = body["sessions"].second
    assert_equal "order_status", replay_row["title"]
    assert_equal "passed", replay_row["outcome"]
    assert_equal replay_run.id, replay_row["agent_run_id"]
  end

  test "an evaluation replay is listed once, even when it wrote to a conversation that is also listed" do
    context, = conversation(at: T0)
    result, = replay(at: T0 + 60, context: context)
    replay(at: T0 + 90)

    rows = listed

    assert_equal 1, rows.count([ "scenario_result", result.id ])
    assert_equal 1, rows.count([ "context", context.id ]), "the conversation also holds a person's turns"
    assert_equal 3, rows.size, "a conversation only evaluation replays wrote to is not listed"
  end

  test "the source filter narrows the query to one kind" do
    context, run = conversation(at: T0)
    result, = replay(at: T0 + 60)
    lone = recording(agent_run: run, at: T0 + 120)

    assert_equal [ [ "context", context.id ] ], listed(source: "dashboard")
    assert_equal [ [ "scenario_result", result.id ] ], listed(source: "evaluation")
    assert_equal [ [ "recording", lone.id ] ], listed(source: "agent")
    assert_equal 1, sessions(source: "agent")["total"]
  end

  test "the agent filter narrows the query to one agent's sessions" do
    mine, run = conversation(at: T0)
    theirs, = conversation(agent: @other_agent, at: T0 + 1)
    replay(agent: @other_agent, at: T0 + 2)
    lone = recording(agent_run: run, at: T0 + 3)
    recording(sandbox_session: nil, agent_run: nil, name: "lander_demo", at: T0 + 4)

    assert_equal [ [ "recording", lone.id ], [ "context", mine.id ] ], listed(agent_id: @agent.id)
    assert_includes listed(agent_id: @other_agent.id), [ "context", theirs.id ]
  end

  test "the failed outcome narrows to failed replays, conversations with a failed run and failed recordings" do
    ok_context, ok_run = conversation(at: T0)
    failed_context, = conversation(at: T0 + 1, status: :failed)
    pinned = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "SupportBot", action_name: "ask",
      created_at: T0 + 2, updated_at: T0 + 2)
    @agent.agent_runs.create!(status: :failed, input_params: { "context_id" => pinned.id.to_s })
    passed, = replay(at: T0 + 3)
    failed, = replay(at: T0 + 4, status: :failed)
    errored, = replay(at: T0 + 5, status: :errored)
    broken = recording(agent_run: ok_run, at: T0 + 6)
    broken.update_columns(status: ActionAgent::SessionRecording.statuses[:failed])
    recording(agent_run: ok_run, at: T0 + 7)

    failed_rows = listed(outcome: "failed")

    assert_equal [
      [ "recording", broken.id ], [ "scenario_result", errored.id ], [ "scenario_result", failed.id ],
      [ "context", pinned.id ], [ "context", failed_context.id ]
    ], failed_rows
    assert_not_includes failed_rows, [ "context", ok_context.id ]
    assert_equal [ [ "scenario_result", passed.id ] ], listed(outcome: "passed")
    assert_equal "failed", sessions(source: "dashboard")["sessions"].find { |row| row["id"] == failed_context.id }["outcome"]
  end

  test "user=me narrows to sessions whose runs ran on behalf of the signed-in user" do
    me = User.create!(email: "me-#{SecureRandom.hex(3)}@example.com", name: "Me", age: 30)
    colleague = User.create!(email: "colleague-#{SecureRandom.hex(3)}@example.com", name: "Colleague", age: 30)
    ActionAgent.current_user_resolver = ->(_controller) { me }
    mine, my_run = conversation(at: T0, input_params: ActionAgent::AgentRun.params_with_actor({}, me))
    conversation(at: T0 + 1, input_params: ActionAgent::AgentRun.params_with_actor({}, colleague))
    my_recording = recording(agent_run: my_run, at: T0 + 2)

    assert_equal [ [ "recording", my_recording.id ], [ "context", mine.id ] ], listed(user: "me")
    assert_equal 3, sessions["total"]
  end

  test "user=me with nobody signed in matches nothing" do
    conversation(at: T0)

    assert_equal [], listed(user: "me")
  end

  test "the date filters narrow to sessions last active in [from, to)" do
    early, = conversation(at: T0)
    middle, = conversation(at: T0 + 1.day)
    late, = conversation(at: T0 + 2.days)

    assert_equal [ [ "context", late.id ], [ "context", middle.id ] ], listed(from: (T0 + 1.day).iso8601)
    assert_equal [ [ "context", early.id ] ], listed(to: (T0 + 1.day).iso8601)
    assert_equal [ [ "context", middle.id ] ], listed(from: (T0 + 1.day).to_date.iso8601, to: (T0 + 2.days).to_date.iso8601)
  end

  test "pages follow the cursor without repeating or skipping sessions that share a time" do
    expected = []
    3.times { expected << [ "context", conversation(at: T0).first.id ] }
    2.times { expected << [ "scenario_result", replay(at: T0).first.id ] }
    older, run = conversation(at: T0 - 60)
    expected << [ "context", older.id ]
    2.times { expected << [ "recording", recording(agent_run: run, at: T0).id ] }

    seen = []
    cursor = nil
    loop do
      body = sessions(per_page: 2, before: cursor)
      seen.concat(body["sessions"].map { |row| [ row["kind"], row["id"] ] })
      break unless body["has_more"]

      cursor = body["next_before"]
    end

    assert_equal seen.uniq, seen
    assert_equal expected.sort, seen.sort
  end

  test "a filter or cursor it cannot read answers 422" do
    [
      { source: "browser" }, { outcome: "declined" }, { user: "42" }, { from: "yesterday" }, { to: "2026-13-40" },
      { before: "nonsense" }, { before: "#{T0.iso8601}|context|x" }
    ].each do |params|
      get "/activeagents/api/sessions", params: params
      assert_response :unprocessable_entity, params.inspect
    end
  end

  test "a caller sees only sessions of agents and recordings they own" do
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    ActionAgent.user_class = "User"
    @agent.update!(user_id: owner.id)
    @other_agent.update!(user_id: owner.id)
    context, run = conversation(at: T0)
    result, = replay(at: T0 + 1)
    lone = recording(agent_run: run, at: T0 + 2)

    ActionAgent.current_user_resolver = ->(_controller) { stranger }
    assert_equal [], listed

    ActionAgent.current_user_resolver = ->(_controller) { owner }
    assert_equal [ [ "recording", lone.id ], [ "scenario_result", result.id ], [ "context", context.id ] ], listed
  end
end
