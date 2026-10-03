# frozen_string_literal: true

require "test_helper"
require_relative "support/explorer_setup"

# A run of a project's evaluation (ProjectEvaluationJob) gives every replay
# the sandbox's browser beside the sandbox: started before the first replay
# when none runs, opened at the project's start URL for each replay, listed
# in the diagnosis roster and recorded in the run's selection. A browser
# that cannot start fails the run before any replay.
class ProjectEvaluationBrowserTest < ActiveSupport::TestCase
  include ExplorerSetup

  MOUNT_URL = "http://dashboard.test/activeagents"

  def setup
    setup_explorer_world!
    @project.update!(start_url: "/orders")
    @agent = @project.target_agent
    @agent.update!(provider: "mock", model: "mock-model")
    @evaluation = @project.evaluation
    @evaluation.scenarios.create!(key: "late_orders", prompt: "Which of my orders shipped late?", position: 0)
    @evaluation.scenarios.create!(key: "order_status", prompt: "Where is order A-17?", position: 1)
    @run = @evaluation.evaluation_runs.create!(status: :pending, selection: { "project_id" => @project.id, "sandbox_id" => @sandbox.session_id })
  end

  def teardown
    restore_explorer_settings!
  end

  def run_project_evaluation
    ActionAgent::ProjectEvaluationJob.perform_now(@project.id, @run.id, MOUNT_URL)
    @run.reload
  end

  test "every replay reaches the sandbox and its browser, started with the saved sign-in and opened at the start URL" do
    state = { "cookies" => [ { "name" => "_shop_session", "value" => "evaluation-session-cookie", "domain" => "127.0.0.1", "path" => "/" } ],
              "origins" => [] }
    @project.assign_storage_state(state).save!

    run = run_project_evaluation

    assert run.complete?, run.error_message
    launch = ExplorerBackend.launches.sole
    assert_equal :headless, launch[:mode]
    assert_equal state, launch[:storage_state]
    recording = ActionAgent::SessionRecording.find_by!(sandbox_session_id: @sandbox.id)
    assert_equal "#{MOUNT_URL}/api/session_recordings/#{recording.id}/events", launch.dig(:recording, :url)

    replays = ActionAgent::AgentRun.where(id: run.scenario_results.pluck(:agent_run_id)).to_a
    assert_equal 2, replays.size
    replays.each do |replay|
      assert_equal [ @sandbox.runtime_server_key, @sandbox.browser_server_key ], [ replay.sandbox_server_key, replay.browser_server_key ]
    end
    assert_equal [ "/orders", "/orders" ], @browser.tool_calls("browser_navigate").map { |call| call.dig("arguments", "url") }
    assert_equal @sandbox.runtime_server_key, run.selection.dig("sandbox", "server_key")
    assert_equal @sandbox.browser_server_key, run.selection.dig("browser", "server_key")
  end

  test "the diagnosis roster lists the browser's tools beside the app's" do
    start_fake_browser!
    runner = ActionAgent::ScenarioEvaluationRunner.new(@evaluation, selection: { sandbox_id: @sandbox.session_id, browser: true })
    runner.send(:ensure_browser_live!)

    roster = runner.send(:tool_roster)

    assert_includes roster.keys, "browser_navigate"
    assert_includes roster.keys, "find_orders"
    assert_empty ExplorerBackend.launches, "a running browser is used as it is"
  end

  test "a browser that cannot start fails the run before the first replay" do
    ExplorerBackend.start_error = RuntimeError.new("Chromium is not installed")

    assert_raises(ArgumentError) { run_project_evaluation }

    run = @run.reload
    assert run.failed?
    assert_match(/browser could not start/, run.error_message)
    assert_equal 0, run.scenario_results.count
    assert_equal 0, @agent.agent_runs.count
  end

  test "a backend that runs no browsers replays against the sandbox alone" do
    ActionAgent.sandbox_backends = { "explorer" => ProjectEvaluationBrowserTest::NoBrowserBackend.name }

    run = run_project_evaluation

    assert run.complete?, run.error_message
    assert_nil run.selection["browser"]
    assert(@agent.agent_runs.all? { |replay| replay.browser_server_key.nil? })
  end

  # The explorer backend without browser verbs.
  class NoBrowserBackend
    def create_sandbox(_session) = {}
    def status(_handle) = { status: "running" }
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0
  end
end
