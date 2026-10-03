# frozen_string_literal: true

require "test_helper"
require_relative "support/explorer_setup"

# POST /api/projects/:id/explorations: the host's quota is asked first, a
# denial starts nothing, and an allowed start records :exploration once,
# gives the project's sandbox a browser and queues the walk.
class ProjectExplorationsApiTest < ActionDispatch::IntegrationTest
  include ExplorerSetup
  include ActiveJob::TestHelper

  BASE = "/activeagents/api/projects"

  def setup
    setup_explorer_world!
    @asked = []
    @used = []
    ActionAgent.quota_checker = ->(_owner, kind) { @asked << kind and nil }
    ActionAgent.usage_recorder = ->(_owner, kind) { @used << kind }
    clear_enqueued_jobs
  end

  def teardown
    restore_explorer_settings!
  end

  def start(**params)
    post "#{BASE}/#{@project.id}/explorations", params: params, as: :json
  end

  test "a quota denial answers 402 and starts nothing" do
    ActionAgent.quota_checker = ->(_owner, kind) { kind == :exploration ? "No explorations left this month" : nil }

    start

    assert_response :payment_required
    assert_equal "No explorations left this month", response.parsed_body["message"]
    assert_equal 0, ActionAgent::Exploration.count
    assert_equal 0, ActionAgent::AgentRun.count
    assert_empty ExplorerBackend.launches
    assert_empty @used
    assert_no_enqueued_jobs only: ActionAgent::ExplorationJob
  end

  test "an allowed start records one exploration, starts the browser headless with the saved sign-in and queues the walk" do
    state = { "cookies" => [ { "name" => "_shop_session", "value" => "saved-session-cookie-value", "domain" => "127.0.0.1", "path" => "/" } ],
              "origins" => [] }
    @project.assign_storage_state(state).save!

    start(budget: { minutes: 5, steps: 40 })

    assert_response :created, response.body
    exploration = ActionAgent::Exploration.find(response.parsed_body.dig("exploration", "id"))
    assert_equal [ "explorer", "pending" ], [ exploration.source, exploration.status ]
    assert_equal({ "minutes" => 5, "steps" => 40 }, exploration.budget)
    assert_equal [ :exploration, :browser_minutes ], @asked
    assert_equal [ :exploration ], @used
    launch = ExplorerBackend.launches.sole
    assert_equal :headless, launch[:mode]
    assert_equal [ "testing" ], launch[:capabilities]
    assert_equal state, launch[:storage_state]
    assert @sandbox.reload.browser_running?
    run = exploration.agent_run
    assert_equal @project.reload.explorer_agent, run.agent
    assert_equal @sandbox.browser_server_key, run.browser_server_key
    assert_equal exploration.session_recording, ActionAgent::SessionRecording.recording.find_by(sandbox_session_id: @sandbox.id)
    assert_enqueued_with(job: ActionAgent::ExplorationJob, args: [ exploration.id, true ])
    assert_not_includes response.body, "saved-session-cookie-value"
  end

  test "a running browser is reused, and the walk does not stop it" do
    start_fake_browser!

    start

    assert_response :created, response.body
    assert_empty ExplorerBackend.launches
    assert_equal [ :exploration ], @asked
    assert_enqueued_with(job: ActionAgent::ExplorationJob, args: [ response.parsed_body.dig("exploration", "id"), false ])
  end

  test "the sandbox must be ready, the target chosen, and one walk runs at a time" do
    @sandbox.update!(status: :expired)
    start
    assert_response :conflict
    assert_equal "sandbox_not_ready", response.parsed_body["code"]
    assert_equal [ :exploration ], @asked

    boot_sandbox!(@project).update!(cloud_run_url: APP_URL)
    start_fake_browser!(@project.reload.current_sandbox_session)
    start
    assert_response :created
    start
    assert_response :conflict
    assert_equal "exploration_running", response.parsed_body["code"]
    assert_equal [ :exploration ], @used
  end

  test "a budget beyond the limits is refused before anything is asked" do
    start(budget: { minutes: 0 })
    assert_response :unprocessable_entity

    start(budget: { steps: 5_000 })
    assert_response :unprocessable_entity
    assert_match(/at most 1000/, response.parsed_body["error"])
    assert_empty @asked
  end

  test "a browser that cannot start answers 422 and creates no exploration" do
    ExplorerBackend.start_error = RuntimeError.new("Chromium is not installed")

    start

    assert_response :unprocessable_entity
    assert_equal "browser_unavailable", response.parsed_body["code"]
    assert_equal 0, ActionAgent::Exploration.count
    assert_empty @used
  end

  test "the explorer walks the app the start queued, then stops the browser it started" do
    mock_explorer!
    start
    exploration = ActionAgent::Exploration.find(response.parsed_body.dig("exploration", "id"))
    ScriptedExplorer.script(
      [ [ :propose_candidate, { prompt: "Which of my orders shipped late?", rubric: "Lists the late orders.", tools: [ "find_orders" ] } ] ],
      [ [ :finish, { summary: "Orders" } ] ]
    )

    walk(exploration, stop_browser: true)

    assert_equal "review", exploration.status
    assert_equal [ @sandbox.session_id ], ExplorerBackend.stops
    assert_equal "stopped", @sandbox.reload.browser_status
    get "/activeagents/api/explorations/#{exploration.id}"
    assert_equal "answerable", response.parsed_body["candidates"].sole["verdict"]
  end

  test "a walk stopped before its job ran still stops the browser the start launched" do
    start
    exploration = ActionAgent::Exploration.find(response.parsed_body.dig("exploration", "id"))
    post "/activeagents/api/explorations/#{exploration.id}/stop", as: :json
    assert_response :success

    walk(exploration, stop_browser: true)

    assert_not_equal "running", exploration.status
    assert_equal [ @sandbox.session_id ], ExplorerBackend.stops
    assert_equal "stopped", @sandbox.reload.browser_status
  end
end
