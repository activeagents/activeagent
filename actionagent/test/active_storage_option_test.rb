# frozen_string_literal: true

require "test_helper"

# ActionAgent.active_storage: one setting for whether the engine attaches
# files, read by the models that would (runs, recording events and
# snapshots), with a service name for where they go.
class ActiveStorageOptionTest < ActiveSupport::TestCase
  # The macros are applied as each model class loads, so load them under the
  # default before a test changes the option.
  def setup
    ActionAgent.active_storage = :auto
    [ ActionAgent::AgentRun, ActionAgent::RecordingEvent, ActionAgent::RecordingSnapshot ].each(&:name)
  end

  def teardown
    ActionAgent.active_storage = :auto
    ActionAgent.active_storage_service = nil
  end

  test "defaults to :auto, which attaches when the host has Active Storage migrated" do
    assert_equal :auto, ActionAgent.active_storage
    assert ActionAgent.active_storage_macros?
    assert ActionAgent.active_storage_available?
    assert ActionAgent::AgentRun.attachments_available?
    assert ActionAgent::RecordingEvent.attachments_available?
    assert ActionAgent::RecordingSnapshot.attachments_available?
  end

  test ":auto without Active Storage loaded applies no macros and attaches nothing" do
    assert_not ActionAgent.active_storage_macros?(loaded: false)
  end

  test "false switches attachments off even when the host has Active Storage" do
    ActionAgent.active_storage = false

    assert_not ActionAgent.active_storage_macros?
    assert_not ActionAgent.active_storage_available?
    assert_not ActionAgent::AgentRun.attachments_available?
    assert_not ActionAgent::RecordingEvent.attachments_available?
    assert_not ActionAgent::RecordingSnapshot.attachments_available?
  end

  test "true requires Active Storage and names the fix when it is missing" do
    ActionAgent.active_storage = true

    assert ActionAgent.active_storage_macros?
    error = assert_raises(ActionAgent::ConfigurationError) { ActionAgent.active_storage_macros?(loaded: false) }
    assert_match(/active_storage:install/, error.message)
  end

  test "the service name reaches the attachment macros, and unset means the host's default" do
    assert_equal({}, ActionAgent.attachment_options)

    ActionAgent.active_storage_service = "recordings"
    assert_equal({ service: :recordings }, ActionAgent.attachment_options)
  end

  test "a run without attachments available refuses files rather than storing them" do
    ActionAgent.active_storage = false
    agent = ActionAgent::Agent.create!(name: "Filer", provider: "mock", model: "mock", instructions: "Hi")
    file = Rack::Test::UploadedFile.new(StringIO.new("a,b\n1,2\n"), "text/csv", original_filename: "rows.csv")

    assert_raises(ActionAgent::AgentRun::AttachmentsUnavailable) { agent.execute("Read the file", attachments: [ file ]) }
  end
end
