# frozen_string_literal: true

require "test_helper"

# The conference-ticket sample: fictional but complete data for a workspace
# that has run nothing yet — an agent, its runs and traces, a replayable
# session that handed off at payment, and an evaluation history that shows a
# caught regression — so Traces, Session Replay and Evaluations have something
# to show, and every page that shows it serves.
class SampleDataConferenceTicketTest < ActionDispatch::IntegrationTest
  Sample = ActionAgent::SampleData::ConferenceTicket

  def setup
    ActionAgent::RecordingAction.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::AgentTemplate.seed_defaults!
  end

  test "seeds an agent with a week of runs and traces" do
    agent = Sample.seed!

    assert_equal "conference-ticket-sample", agent.slug
    assert_includes agent.tools, "playwright_mcp"
    assert_equal 7, agent.agent_runs.count
    assert agent.agent_runs.all?(&:complete?)

    traces = ActionAgent::TelemetryTrace.where(agent_id: agent.id)
    assert_equal 7, traces.count
    assert_equal [ "ConferenceTicketAgent" ], traces.distinct.pluck(:agent_class)
    assert traces.all? { |trace| trace.total_input_tokens.positive? && trace.total_duration_ms.positive? }

    live = agent.agent_runs.reorder(created_at: :desc).first
    trace = traces.find_by!(trace_id: live.trace_id)
    names = trace.spans.map { |span| span["name"] }
    assert_includes names, "agent.prompt"
    assert_includes names, "llm.generate"
    assert_includes names, "tool.browser_navigate"
    assert_includes names, "tool.browser_fill_form"
    assert_includes names, "tool.request_handoff"
    assert_equal live.input_tokens, trace.total_input_tokens
    assert_equal "OK", trace.status
    assert_equal true, trace.resource_attributes["sample"]
  end

  test "the newest run has a completed recording that offers Take Over at the ticket page" do
    agent = Sample.seed!
    live = agent.agent_runs.reorder(created_at: :desc).first

    recording = ActionAgent::SessionRecording.find_by!(agent_run: live)
    assert recording.completed?
    types = recording.recording_actions.order(:sequence).pluck(:action_type)
    assert_equal "navigate", types.first
    assert_includes types, "form_fill"
    assert_equal "handoff", types.last
    assert_equal Sample::TICKETS_URL, recording.metadata["handoff_state"]["url"]
    assert_equal({ "Name" => "Ada Lovelace", "Email" => "ada@example.com" }, recording.metadata["handoff_state"]["form_values"])
    assert_operator recording.recording_actions.order(:sequence).last.timestamp_ms, :>, recording.recording_actions.order(:sequence).first.timestamp_ms
  end

  test "the evaluation history shows a caught regression and its fix" do
    agent = Sample.seed!
    evaluation = agent.evaluations.find_by!(name: "Ticket run safety")

    assert_equal 3, evaluation.scenarios.count
    older, latest = evaluation.evaluation_runs.order(:created_at).to_a
    assert_operator older.created_at, :<, latest.created_at

    # Before the no-payment rule the agent clicked Pay in both registration
    # scenarios; only the sold-out one passed.
    assert_equal 1, older.samples_passed
    assert_equal %w[happy_path no_invented_details], older.scenario_results.failed.map { |result| result.scenario.key }.sort
    failed = older.scenario_results.failed.find { |result| result.scenario.key == "happy_path" }
    assert_equal "forbidden_content", failed.fault
    assert_match(/never click Pay/, failed.recommendation)
    assert_includes failed.tool_names, "browser_click"
    assert_equal 1, older.scores["_recommendations"].size
    assert_equal 2, older.scores["_recommendations"].first["count"]

    assert_equal 3, latest.samples_passed
    assert latest.scenario_results.all?(&:passed?)
    assert_includes latest.scenario_results.find_by!(scenario: evaluation.scenarios.find_by!(key: "happy_path")).tool_names, "request_handoff"
    assert_operator latest.average_score, :>, older.average_score
    assert_equal [ "claude-sonnet-5" ], latest.models
    assert_operator latest.scenario_results.sum(:cost), :>, 0
  end

  test "seeding twice adds nothing, and clear! removes everything the sample created" do
    agent = Sample.seed!
    counts = -> { [ ActionAgent::Agent.count, ActionAgent::AgentRun.count, ActionAgent::TelemetryTrace.count,
                    ActionAgent::SessionRecording.count, ActionAgent::Evaluation.count ] }
    seeded = counts.call

    assert_equal agent, Sample.seed!
    assert_equal seeded, counts.call
    assert Sample.seeded?

    assert_equal 1, Sample.clear!
    assert_equal [ 0, 0, 0, 0, 0 ], counts.call
    assert_equal 0, ActionAgent::RecordingAction.count
    assert_equal 0, Sample.clear!
  end

  test "every dashboard page that shows the sample serves it" do
    agent = Sample.seed!
    live = agent.agent_runs.reorder(created_at: :desc).first
    recording = ActionAgent::SessionRecording.find_by!(agent_run: live)
    evaluation = agent.evaluations.first
    trace = ActionAgent::TelemetryTrace.find_by!(trace_id: live.trace_id)

    get "/activeagents/api/agents"
    assert_response :success
    assert_includes response.body, "Conference Ticket Agent (sample)"

    get "/activeagents/api/agents/#{agent.id}/runs"
    assert_response :success

    get "/activeagents/api/runs/#{live.id}"
    assert_response :success

    get "/activeagents/api/traces"
    assert_response :success
    assert_includes response.body, "ConferenceTicketAgent"

    # The show route resolves a trace_id (or a prefix of one) before a numeric
    # id, so a random trace_id that happens to start with this trace's row
    # number would win; address the trace the way the dashboard links it.
    get "/activeagents/api/traces/#{trace.trace_id}"
    assert_response :success
    assert_includes response.body, "tool.request_handoff"

    get "/activeagents/console/traces/metrics"
    assert_response :success

    get "/activeagents/api/evaluations"
    assert_response :success
    assert_includes response.body, "Ticket run safety"

    get "/activeagents/api/evaluations/#{evaluation.id}"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 3, body.dig("evaluation", "latest_run", "samples_passed") || body.dig("latest_run", "samples_passed")

    get "/activeagents/api/session_recordings/#{recording.id}"
    assert_response :success
    assert_equal Sample::TICKETS_URL, JSON.parse(response.body).dig("recording", "handoff_state", "url")

    get "/activeagents/api/tools"
    assert_response :success
  end
end
