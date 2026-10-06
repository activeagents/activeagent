# frozen_string_literal: true

require "test_helper"

# A browser run can stop for a person. An agent with the platform's browser
# tools (playwright_mcp) has its browser actions written to a session
# recording, and calls request_handoff when the page asks for something only
# its owner may give — payment details, a login code. The recording then
# carries where the agent stopped and what it entered, and Session Replay's
# Take Over Session hands that page to the person. The conference-ticket demo:
# the agent registers, the presenter pays.
class BrowserHandoffTest < ActionDispatch::IntegrationTest
  # Stands in for the Playwright MCP server the platform runs: answers every
  # browser tool with a snapshot of a ticket page.
  class FakeBrowser
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call_tool(name, arguments = {})
      @calls << [ name, arguments ]
      { text: "- heading \"Tickets\" [ref=e1]\n- button \"Register\" [ref=e2]", is_error: false }
    end
  end

  def setup
    ActionAgent::RecordingAction.delete_all
    ActionAgent::RecordingEvent.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::Agent.delete_all
    @browser = FakeBrowser.new
    ActionAgent::PlaywrightMCPClient.instance_variable_set(:@instance, @browser)
  end

  def teardown
    ActionAgent::PlaywrightMCPClient.reset!
  end

  # The browser actions a run recorded, oldest first, as the event data the
  # recorder stores (tool_name, action_type, parameters, status).
  def recorded_actions(recording)
    recording.recording_events.where(kind: "action").order(:id).flat_map(&:events).map { |event| event["data"] }
  end

  def build_run(tools: %w[playwright_mcp])
    agent = ActionAgent::Agent.create!(
      name: "Ticket Agent",
      provider: "mock",
      model: "mock",
      instructions: "Register the attendee, then stop before paying.",
      tools: tools
    )
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :pending)
    [ agent, run ]
  end

  def service_for(agent, run)
    ActionAgent::AgentExecutionService.new(agent, run)
  end

  test "the browser tools offer request_handoff alongside the browser actions" do
    names = ActionAgent::AgentToolbox.definitions_for(%w[playwright_mcp]).map { |tool| tool[:name] }

    assert_includes names, "request_handoff"
    assert_includes names, "browser_navigate"
    assert_includes names, "browser_click"
  end

  test "browser actions are recorded on the run's session" do
    agent, run = build_run

    result = service_for(agent, run).execute_tool("browser_navigate", url: "https://example.com/tickets")

    assert_match(/Register/, result[:text])
    assert_equal [ [ "browser_navigate", { url: "https://example.com/tickets" } ] ], @browser.calls
    recording = ActionAgent::SessionRecording.find_by!(agent_run: run)
    assert recording.recording?
    actions = recorded_actions(recording)
    assert_equal [ "navigate" ], actions.map { |action| action["action_type"] }
    assert_equal "https://example.com/tickets", actions.first.dig("parameters", "url")
  end

  test "typing and form filling reach the browser by target and are recorded" do
    agent, run = build_run
    service = service_for(agent, run)

    service.execute_tool("browser_type", ref: "e41", element: "Name", text: "Ada Lovelace")
    service.execute_tool("browser_fill_form", fields: [ { "ref" => "e42", "name" => "Email", "type" => "textbox", "value" => "ada@example.com" } ])
    service.execute_tool("browser_click", ref: "e48", element: "Continue")

    assert_equal [ "browser_type", { target: "e41", element: "Name", text: "Ada Lovelace" } ], @browser.calls[0]
    assert_equal [ "browser_fill_form", { fields: [ { target: "e42", name: "Email", type: "textbox", value: "ada@example.com" } ] } ], @browser.calls[1]
    assert_equal [ "browser_click", { target: "e48", element: "Continue" } ], @browser.calls[2]

    recording = ActionAgent::SessionRecording.find_by!(agent_run: run)
    actions = recorded_actions(recording)
    assert_equal %w[type form_fill click], actions.map { |action| action["action_type"] }
    assert_equal "e41", actions.first.dig("parameters", "ref")
    assert_equal "e48", actions.last.dig("parameters", "ref")
  end

  test "a browser action without an element ref is refused, not sent" do
    agent, run = build_run

    result = service_for(agent, run).execute_tool("browser_click", element: "Continue")

    assert_match(/ref/, result[:error])
    assert_empty @browser.calls
  end

  test "an agent without the browser tools is not recorded" do
    agent, run = build_run(tools: %w[memory])

    service_for(agent, run).execute_tool("browser_navigate", url: "https://example.com/tickets")

    assert_nil ActionAgent::SessionRecording.find_by(agent_run: run)
  end

  test "request_handoff keeps where the agent stopped and what it entered, never a secret" do
    agent, run = build_run
    service = service_for(agent, run)
    service.execute_tool("browser_navigate", url: "https://example.com/tickets")
    service.execute_tool("browser_click", ref: "e2", element: "Register")

    result = service.execute_tool(
      "request_handoff",
      reason: "payment details",
      url: "https://tickets.example.com/checkout/abc123",
      form_values: { "Name" => "Ada Lovelace", "Email" => "ada@example.com", "Card number" => "4242 4242 4242 4242" },
      instructions: "Pay with the company card, then forward the receipt."
    )

    assert result[:handed_off], result.inspect
    assert_equal "payment details", result[:reason]
    assert_equal({ "Name" => "Ada Lovelace", "Email" => "ada@example.com" }, result[:form_values])
    assert_match(/Take Over Session/, result[:message])

    recording = ActionAgent::SessionRecording.find_by!(agent_run: run)
    assert_equal result[:recording_id], recording.id
    state = recording.metadata["handoff_state"]
    assert_equal "https://tickets.example.com/checkout/abc123", state["url"]
    assert_equal({ "Name" => "Ada Lovelace", "Email" => "ada@example.com" }, state["form_values"])
    assert_not_includes recording.metadata.to_json, "4242"

    handoff = recording.recording_actions.order(:sequence).last
    assert_equal "handoff", handoff.action_type
    assert_equal "payment details", handoff.value
    assert_equal "https://tickets.example.com/checkout/abc123", handoff.metadata["url"]
    assert_equal "Pay with the company card, then forward the receipt.", handoff.metadata["instructions"]
    assert_equal [ "handoff" ], recording.recording_actions.order(:sequence).pluck(:action_type)
    assert_equal %w[browser_navigate browser_click], recorded_actions(recording).map { |action| action["tool_name"] }
  end

  test "request_handoff needs the browser tools and a page to continue on" do
    agent, run = build_run(tools: %w[memory])
    assert_match(/playwright_mcp/, service_for(agent, run).execute_tool("request_handoff", reason: "payment", url: "https://x.test")[:error])

    agent, run = build_run
    assert_match(/url/, service_for(agent, run).execute_tool("request_handoff", reason: "payment")[:error])
    assert_nil ActionAgent::SessionRecording.find_by(agent_run: run)
  end

  test "a run completes its recording when it ends" do
    agent, run = build_run
    service = service_for(agent, run)
    service.execute_tool("browser_navigate", url: "https://example.com/tickets")

    service.call

    assert ActionAgent::SessionRecording.find_by!(agent_run: run).completed?
    assert_nil run.reload.error_message
  end

  test "Take Over Session hands the person the page and what was entered, without browser secrets" do
    agent, run = build_run
    service = service_for(agent, run)
    service.execute_tool("browser_navigate", url: "https://example.com/tickets")
    service.execute_tool(
      "request_handoff",
      reason: "payment details",
      url: "https://tickets.example.com/checkout/abc123",
      form_values: { "Name" => "Ada Lovelace" }
    )
    recording = ActionAgent::SessionRecording.find_by!(agent_run: run)

    get "/activeagents/api/session_recordings/#{recording.id}"
    assert_response :success
    shown = JSON.parse(response.body)["recording"]
    assert_equal "https://tickets.example.com/checkout/abc123", shown.dig("handoff_state", "url")
    assert_equal({ "Name" => "Ada Lovelace" }, shown.dig("handoff_state", "form_values"))
    assert_not shown["handoff_state"].key?("cookies")

    post "/activeagents/api/session_recordings/#{recording.id}/handoff"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "https://tickets.example.com/checkout/abc123", body.dig("handoff_state", "url")
    assert_equal({ "Name" => "Ada Lovelace" }, body.dig("handoff_state", "form_values"))
    continuation = ActionAgent::SessionRecording.find(body["continuation_recording_id"])
    assert_equal recording.id, continuation.metadata["parent_recording_id"]
    assert continuation.recording?
  end
end
