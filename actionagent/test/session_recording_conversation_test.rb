# frozen_string_literal: true

require "test_helper"

# A session recording can belong to a conversation rather than a run, says
# where it came from, and copies its owner onto every event it stores.
class SessionRecordingConversationTest < ActiveSupport::TestCase
  def setup
    ActionAgent::RecordingEvent.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::AgentContext.delete_all
    ActionAgent::Agent.delete_all
    User.delete_all

    @agent = ActionAgent::Agent.create!(name: "Support Bot", provider: "mock", model: "mock")
    @context = ActionAgent::AgentContext.create!(contextable: @agent, agent_name: "SupportBot", action_name: "ask")
  end

  def teardown
    ActionAgent.user_class = nil
  end

  test "a recording may belong to a conversation alone" do
    recording = ActionAgent::SessionRecording.start!(agent_context: @context, source: "dashboard")

    assert_equal @context, recording.agent_context
    assert_match(/\Asupportbot_/, recording.name)
  end

  test "a recording with no run, sandbox or conversation is refused" do
    assert_raises(ActiveRecord::RecordInvalid) { ActionAgent::SessionRecording.start! }
  end

  test "a recording's source is agent, dashboard, or not recorded" do
    assert_raises(ActiveRecord::RecordInvalid) do
      ActionAgent::SessionRecording.start!(agent_context: @context, source: "visitor")
    end
    assert_nil ActionAgent::SessionRecording.start!(agent_context: @context).source
  end

  test "a conversation's recording is owned by the conversation agent's owner, and so are its events" do
    owner = User.create!(email: "owner-#{SecureRandom.hex(3)}@example.com", name: "Owner", age: 30)
    ActionAgent.user_class = "User"
    @agent.update!(user_id: owner.id)

    recording = ActionAgent::SessionRecording.start!(agent_context: @context, source: "dashboard")
    event = recording.record_server_event!(kind: "marker", started_at: Time.current, data: { "label" => "start" })

    assert_equal owner.id, recording.user_id
    assert_equal owner.id, event.user_id
    assert_equal 1, recording.reload.event_count
    assert_equal event.byte_size, recording.event_bytes
  end

  test "an event kind outside the list is refused" do
    recording = ActionAgent::SessionRecording.start!(agent_context: @context)

    assert_raises(ActiveRecord::RecordInvalid) do
      recording.record_server_event!(kind: "llm", started_at: Time.current, data: {})
    end
  end
end
