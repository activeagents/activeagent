# frozen_string_literal: true

require "test_helper"

# Deleting a session recording is a privileged action the host's permission
# checker decides.
class SessionRecordingDeletionTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::RecordingEvent.delete_all
    ActionAgent::RecordingAction.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all

    agent = ActionAgent::Agent.create!(name: "Browser Bot", provider: "mock", model: "mock")
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :complete)
    @recording = ActionAgent::SessionRecording.start!(agent_run: run, source: "agent")
  end

  def teardown
    ActionAgent.permission_checker = nil
  end

  def delete_recording
    delete "/activeagents/api/session_recordings/#{@recording.id}"
  end

  test "deleting a recording asks the permission checker about :manage_recordings" do
    asked = []
    ActionAgent.permission_checker = ->(_user, action, subject) { asked << [ action, subject ]; false }

    delete_recording

    assert_response :forbidden
    assert_equal "manage_recordings", response.parsed_body["permission"]
    assert ActionAgent::SessionRecording.exists?(@recording.id)
    assert_equal [ [ :manage_recordings, @recording ] ], asked
  end

  test "a recording the checker allows is deleted with its events" do
    @recording.record_server_event!(kind: "marker", started_at: Time.current, data: { "label" => "start" })
    ActionAgent.permission_checker = ->(*) { true }

    delete_recording

    assert_response :success
    assert_not ActionAgent::SessionRecording.exists?(@recording.id)
    assert_equal 0, ActionAgent::RecordingEvent.count
  end
end
