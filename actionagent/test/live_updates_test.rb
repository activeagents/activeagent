# frozen_string_literal: true

require "test_helper"

# What the engine broadcasts over Action Cable: that a record changed, as
# { type, id, status }, never the record itself. Clients refetch it over the
# authorized JSON API.
class LiveUpdatesTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  def setup
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::SandboxSession.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  test "a run's status change is announced on its stream and its agent's, without its content" do
    run = @agent.agent_runs.create!(input_prompt: "my account number is 1234", status: :pending)

    run.update!(status: :complete, output: "here is your balance")

    expected = { "type" => "update", "id" => run.id, "status" => "complete" }
    assert_equal [ expected ], messages_on("agent_run_#{run.id}")
    assert_equal [ expected ], messages_on("agent_runs_#{@agent.id}")
  end

  test "a sandbox's status change is announced without its summary" do
    sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")

    ActionAgent::SandboxProvisionJob.new.send(:broadcast_sandbox_update, sandbox)

    assert_equal [ { "type" => "status_update", "id" => sandbox.session_id, "status" => sandbox.status } ],
      messages_on("sandbox_#{sandbox.session_id}")
  end

  test "a sandbox run is announced without its task, result or error" do
    sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp")
    job = ActionAgent::SandboxRunJob.new

    job.send(:broadcast_run_started, sandbox, "run-1")
    job.send(:broadcast_run_complete, sandbox, "run-1", { status: "completed", result: "the answer", task: "the question" })
    job.send(:broadcast_run_error, sandbox, "run-2")

    assert_equal [
      { "type" => "run_started", "id" => "run-1", "status" => "running" },
      { "type" => "run_complete", "id" => "run-1", "status" => "completed" },
      { "type" => "run_error", "id" => "run-2", "status" => "failed" }
    ], messages_on("sandbox_#{sandbox.session_id}")
  end

  test "nothing is broadcast, and nothing fails, when the host has not loaded Action Cable" do
    run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)

    ActionAgent::LiveUpdates.stub(:available?, false) do
      ActionCable.server.stub(:broadcast, ->(*) { flunk "broadcast without Action Cable" }) do
        assert_not ActionAgent::LiveUpdates.broadcast("agent_run_#{run.id}", type: "update", id: run.id, status: "running")
        run.update!(status: :running)
      end
    end

    assert run.reload.running?
    assert_empty messages_on("agent_run_#{run.id}")
  end

  test "Action Cable counts as loaded only when it is defined and has a server" do
    assert ActionAgent::LiveUpdates.available?, "loaded"

    with_action_cable(nil) { assert_not ActionAgent::LiveUpdates.available?, "not defined" }
    with_action_cable(Module.new) { assert_not ActionAgent::LiveUpdates.available?, "defined without a server" }
  end

  private

  def messages_on(stream)
    broadcasts(stream).map { |message| JSON.parse(message) }
  end

  # Replaces the top-level ActionCable constant for the block, or removes it
  # when +replacement+ is nil.
  def with_action_cable(replacement)
    original = Object.send(:remove_const, :ActionCable)
    Object.const_set(:ActionCable, replacement) if replacement
    yield
  ensure
    Object.send(:remove_const, :ActionCable) if Object.const_defined?(:ActionCable, false)
    Object.const_set(:ActionCable, original)
  end
end
