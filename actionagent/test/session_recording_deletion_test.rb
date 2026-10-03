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

  # An event whose payload is too large to keep in the row.
  def attached_event
    event = @recording.recording_events.new(kind: "console")
    event.events = [ {
      "at" => ActionAgent::RecordingEvent.milliseconds(Time.current),
      "data" => { "message" => SecureRandom.alphanumeric(ActionAgent::RecordingEvent::INLINE_PAYLOAD_LIMIT * 2) }
    } ]
    event.save!
    event
  end

  # Renames the Active Storage tables for the block, as in a host that loads
  # Active Storage but never ran its migrations.
  def without_active_storage_tables
    connection = ActiveRecord::Base.connection
    tables = %w[active_storage_attachments active_storage_blobs]
    tables.each { |table| connection.rename_table(table, "#{table}_unmigrated") }
    connection.schema_cache.clear!
    yield
  ensure
    tables.each { |table| connection.rename_table("#{table}_unmigrated", table) if connection.table_exists?("#{table}_unmigrated") }
    connection.schema_cache.clear!
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

  test "deleting a recording purges its attached event payloads" do
    blob = attached_event.payload_file.blob

    assert_enqueued_with(job: ActiveStorage::PurgeJob, args: [ blob ]) { delete_recording }

    assert_response :success
    assert_equal 0, ActionAgent::RecordingEvent.count
    assert_not ActiveStorage::Attachment.exists?(record_type: ActionAgent::RecordingEvent.polymorphic_name)
  end

  test "a recording is deleted in a host whose Active Storage tables were never migrated" do
    @recording.record_server_event!(kind: "marker", started_at: Time.current, data: { "label" => "start" })

    without_active_storage_tables do
      assert_not ActionAgent::RecordingEvent.attachments_available?
      delete_recording
    end

    assert_response :success
    assert_not ActionAgent::SessionRecording.exists?(@recording.id)
    assert_equal 0, ActionAgent::RecordingEvent.count
  end
end
