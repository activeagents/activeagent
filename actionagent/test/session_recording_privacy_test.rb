# frozen_string_literal: true

require "test_helper"

# Every read path of a recording redacts the same way (#393): the show
# timeline and the export cassette used to return the cleartext that
# /actions masked for the very same action.
class SessionRecordingPrivacyTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::RecordingAction.delete_all
    ActionAgent::SessionRecording.delete_all

    @recording = ActionAgent::SessionRecording.start_user_session!(page_url: "https://example.com/login")
    @recording.record_action!(
      action_type: "type",
      selector: "input[name=password]",
      value: "hunter2secret",
      metadata: { "password" => "hunter2secret", "url" => "https://example.com/login" }
    )
  end

  test "the action list redacts the value and its metadata" do
    get "/activeagents/api/session_recordings/#{@recording.id}/actions"

    assert_response :success
    action = JSON.parse(response.body)["actions"].first
    assert_equal "[REDACTED]", action["value"]
    assert_nil action["metadata"]["password"]
  end

  test "the show timeline redacts like the action list" do
    get "/activeagents/api/session_recordings/#{@recording.id}"

    assert_response :success
    entry = JSON.parse(response.body).dig("recording", "timeline").first
    assert_equal "[REDACTED]", entry["value"]
    assert_nil entry["metadata"]["password"]
    assert_equal "https://example.com/login", entry["metadata"]["url"]
    assert_not_includes response.body, "hunter2secret"
  end

  test "the export cassette redacts like the action list" do
    post "/activeagents/api/session_recordings/#{@recording.id}/export"

    assert_response :success
    exported = JSON.parse(response.body).dig("cassette", "actions").first
    assert_equal "[REDACTED]", exported["value"]
    assert_nil exported["metadata"]["password"]
    assert_not_includes response.body, "hunter2secret"
  end

  # The handoff state is a copy of the visitor's browser: cookies and web
  # storage. Stripping only the top level of the metadata left the same
  # secrets readable one key down, and as the top-level handoff_state key.
  test "show strips cookies and web storage from the nested handoff state" do
    @recording.update!(metadata: @recording.metadata.merge(
      "handoff_state" => {
        "url" => "https://example.com/checkout",
        "cookies" => [ { "name" => "_session", "value" => "sekrit-cookie" } ],
        "local_storage" => { "auth_token" => "lst-secret" },
        "session_storage" => { "csrf" => "sst-secret" }
      }
    ))

    get "/activeagents/api/session_recordings/#{@recording.id}"

    assert_response :success
    body = JSON.parse(response.body)["recording"]
    assert_equal "https://example.com/checkout", body.dig("handoff_state", "url")
    assert_nil body.dig("handoff_state", "cookies")
    assert_nil body.dig("metadata", "handoff_state", "cookies")
    %w[sekrit-cookie lst-secret sst-secret].each { |secret| assert_not_includes response.body, secret }
  end
end

# In a per-user install the list has to show the recordings the caller can
# open: the owner column is written at creation, and recordings made inside
# the caller's sandbox are reachable even when it was never written (#393).
class SessionRecordingOwnershipTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::RecordingAction.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::SandboxSession.delete_all
    User.delete_all

    @user = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    @other = User.create!(email: "other-#{SecureRandom.hex(3)}@example.com", name: "Other", age: 30)
    ActionAgent.user_class = "User"
    ActionAgent.current_user_resolver = ->(_controller) { @user }
  end

  def teardown
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
  end

  def listed_ids(path = "/activeagents/api/session_recordings")
    get path
    assert_response :success
    JSON.parse(response.body)["recordings"].map { |recording| recording["id"] }
  end

  test "a user session started through the API is owned by the caller and listed for them" do
    post "/activeagents/api/session_recordings/start_user_session", params: { page_url: "https://example.com/" }

    assert_response :created
    id = JSON.parse(response.body)["recording_id"]
    assert_equal @user.id, ActionAgent::SessionRecording.find(id).user_id

    assert_includes listed_ids, id
    assert_includes listed_ids("/activeagents/api/session_recordings/recent"), id
  end

  test "a recording made in the caller's sandbox is listed even with no owner column written" do
    sandbox = ActionAgent::SandboxSession.new(sandbox_type: "terminal")
    sandbox.user_id = @user.id
    sandbox.save!
    recording = ActionAgent::SessionRecording.start!(sandbox_session: sandbox)
    recording.update_column(:user_id, nil)

    assert_includes listed_ids, recording.id
  end

  test "a recording inherits the owner of the sandbox it records" do
    sandbox = ActionAgent::SandboxSession.new(sandbox_type: "terminal")
    sandbox.user_id = @user.id
    sandbox.save!

    recording = ActionAgent::SessionRecording.start!(sandbox_session: sandbox)

    assert_equal @user.id, recording.user_id
  end

  test "another user's recordings are not listed" do
    theirs = ActionAgent::SessionRecording.start_user_session!(page_url: "https://example.com/", owner: @other)

    assert_not_includes listed_ids, theirs.id
    assert_not_includes listed_ids("/activeagents/api/session_recordings/recent"), theirs.id
  end
end
