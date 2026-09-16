# frozen_string_literal: true

require "test_helper"

# A query value can arrive as a container (`minutes[]=1&minutes[]=2`, or
# `page[x]=1`), and neither Array nor ActionController::Parameters responds
# to `to_i`. Reading them directly raised NoMethodError and turned a
# malformed query into a 500 on every list the dashboard paginates or
# windows. A multi-valued param means its first value; a nested object is
# malformed and floors to the default.
class ParamCoercionTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    @agent.agent_runs.create!(input_prompt: "hi", output: "hello", status: :complete)
  end

  test "agent runs coerce container-valued minutes, page and per_page" do
    get "/activeagents/api/agents/#{@agent.id}/runs", params: { minutes: [ 1, 2 ], page: { x: 1 }, per_page: [ 5 ] }

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal 1, body["runs"].length
    assert_equal 5, body["meta"]["per_page"]
    assert_equal 1, body["meta"]["page"]
  end

  test "agent analytics coerces a container-valued days param" do
    get "/activeagents/api/agents/#{@agent.id}/analytics", params: { days: [ 7, 30 ] }

    assert_response :success, response.body
  end

  test "interactions coerce container-valued minutes and limit" do
    context = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "SupportAgent", action_name: "respond")
    context.add_user_message("Where is order 88213?")

    get "/activeagents/api/interactions", params: { minutes: [ 60, 120 ], limit: { n: 10 } }

    assert_response :success, response.body
    assert_equal 1, JSON.parse(response.body)["interactions"].length
  end

  test "session recordings coerce container-valued page, per_page, after_sequence and limit" do
    recording = ActionAgent::SessionRecording.start_user_session!(page_url: "https://example.com/")
    recording.record_action!(action_type: "click", selector: "button")

    get "/activeagents/api/session_recordings", params: { page: [ 1 ], per_page: { n: 20 } }
    assert_response :success, response.body
    assert_equal 1, JSON.parse(response.body).dig("pagination", "page")

    get "/activeagents/api/session_recordings/#{recording.id}/actions", params: { after_sequence: [ 0 ], limit: { n: 5 } }
    assert_response :success, response.body
    assert_equal 1, JSON.parse(response.body)["actions"].size
  end

  test "sandbox compare rejects a providers value that is not a list of names" do
    sandbox = ActionAgent::SandboxSession.create!(session_id: SecureRandom.uuid, status: :ready, expires_at: 1.hour.from_now)

    post "/activeagents/api/sandboxes/compare", params: { task: "Take a screenshot", providers: "anthropic", sandbox_id: sandbox.session_id }
    assert_response :bad_request, response.body

    post "/activeagents/api/sandboxes/compare", params: { task: "Take a screenshot", providers: { a: "anthropic" }, sandbox_id: sandbox.session_id }
    assert_response :bad_request, response.body
  end
end
