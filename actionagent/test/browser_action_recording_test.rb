# frozen_string_literal: true

require "test_helper"

# An agent's browser tool calls are recorded on its run's session recording
# as `action` events, with what they typed masked before it is stored.
class BrowserActionRecordingTest < ActiveSupport::TestCase
  def setup
    ActionAgent::RecordingEvent.delete_all
    ActionAgent::SessionRecording.delete_all
    ActionAgent::ProviderKey.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all

    @agent = ActionAgent::Agent.create!(name: "Browser Bot", provider: "mock", model: "mock")
    @run = @agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :running)
    @service = ActionAgent::AgentExecutionService.new(@agent, @run)
  end

  def with_tool_result(result, &block)
    ActionAgent::AgentToolbox.stub(:call, ->(*, **) { result }, &block)
  end

  def recorded_actions
    ActionAgent::RecordingEvent.where(kind: "action").flat_map(&:events).map { |event| event["data"] }
  end

  test "browser_type is recorded once, with the typed text masked" do
    result = with_tool_result({ text: "Typed into the password field" }) do
      @service.execute_tool("browser_type", element: "Password", ref: "e12", text: "hunter2secret")
    end

    assert_equal({ text: "Typed into the password field" }, result)
    action = recorded_actions.sole
    assert_equal "browser_type", action["tool_name"]
    assert_equal "type", action["action_type"]
    assert_equal "[REDACTED]", action.dig("parameters", "text")
    assert_equal "e12", action.dig("parameters", "ref")
    assert_equal @run.trace_id, action["trace_id"]

    recording = ActionAgent::SessionRecording.sole
    assert_equal @run.id, recording.agent_run_id
    assert_equal "agent", recording.source
    assert_equal 1, recording.event_count
    assert_not_includes ActionAgent::RecordingEvent.all.map { |row| row.events.to_json }.join, "hunter2secret"
  end

  test "browser_fill_form is recorded with every field value masked" do
    with_tool_result({ text: "Filled" }) do
      @service.execute_tool("browser_fill_form", fields: [
        { name: "Email", type: "textbox", ref: "e3", value: "person@example.com" },
        { name: "Password", type: "textbox", ref: "e4", value: "hunter2secret" }
      ])
    end

    fields = recorded_actions.sole.dig("parameters", "fields")
    assert_equal [ "[REDACTED]", "[REDACTED]" ], fields.map { |field| field["value"] }
    assert_equal %w[Email Password], fields.map { |field| field["name"] }
  end

  test "browser_handle_dialog is recorded with its prompt text masked" do
    with_tool_result({ text: "Dialog answered with s3cret-answer" }) do
      @service.execute_tool("browser_handle_dialog", accept: true, promptText: "s3cret-answer")
    end

    action = recorded_actions.sole
    assert_equal "dialog", action["action_type"]
    assert_equal({ "accept" => true, "promptText" => "[REDACTED]" }, action["parameters"])
    assert_equal "Dialog answered with [REDACTED]",
      ActionAgent::BrowserToolRedaction.redact_text("browser_handle_dialog", "Dialog answered with s3cret-answer", { promptText: "s3cret-answer" })
  end

  test "the owner's credentials are scrubbed from what is recorded" do
    ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-recorded-credential-1234")

    with_tool_result({ text: "Navigated" }) do
      @service.execute_tool("browser_navigate", url: "https://example.com/?key=sk-recorded-credential-1234")
    end

    assert_equal "https://example.com/?key=[REDACTED]", recorded_actions.sole.dig("parameters", "url")
  end

  test "a tool that is not a browser tool records nothing" do
    with_tool_result({ text: "ok" }) { @service.execute_tool("browse_page", url: "https://docs.activeagents.ai/") }

    assert_equal 0, ActionAgent::SessionRecording.count
    assert_equal 0, ActionAgent::RecordingEvent.count
  end

  test "a failure to record leaves the tool result as it was" do
    ActionAgent::SessionRecording.stub(:start!, ->(**) { raise ActiveRecord::ConnectionTimeoutError, "no connection" }) do
      result = with_tool_result({ text: "Clicked" }) { @service.execute_tool("browser_click", element: "Buy", ref: "e7") }

      assert_equal({ text: "Clicked" }, result)
    end
    assert_equal 0, ActionAgent::RecordingEvent.count
  end

  test "a failing browser call is recorded as an error, and its result is unchanged" do
    result = ActionAgent::AgentToolbox.stub(:call, ->(*, **) { raise "page crashed while typing hunter2secret" }) do
      @service.execute_tool("browser_type", ref: "e12", text: "hunter2secret")
    end

    assert_match(/browser_type failed: page crashed/, result[:error])
    action = recorded_actions.sole
    assert_equal "error", action["status"]
    assert_equal "page crashed while typing [REDACTED]", action["error"]
  end

  test "a run's browser calls share one recording" do
    with_tool_result({ text: "ok" }) do
      @service.execute_tool("browser_navigate", url: "https://example.com/")
      @service.execute_tool("browser_click", element: "Sign in", ref: "e2")
    end

    assert_equal 1, ActionAgent::SessionRecording.count
    assert_equal %w[browser_navigate browser_click], recorded_actions.map { |action| action["tool_name"] }
    assert_equal 2, ActionAgent::SessionRecording.sole.event_count
  end
end
