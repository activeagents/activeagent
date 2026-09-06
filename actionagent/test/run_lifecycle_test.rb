# frozen_string_literal: true

require "test_helper"

# The agent-execution job's terminal states (#377): a failed run is never
# re-executed, and a cancel that lands mid-execution is not overwritten by
# the job that was still running it.
class RunLifecycleTest < ActiveSupport::TestCase
  def setup
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    @run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
  end

  test "the engine's jobs do not blanket-retry on StandardError" do
    rescued = ActionAgent::ApplicationJob.rescue_handlers.map(&:first)

    assert_not_includes rescued, "StandardError",
      "a retry re-runs a non-idempotent generation and re-bills it"
  end

  test "a failed run is not executed again" do
    calls = 0
    exploding = ->(_agent, _run) { calls += 1; raise "provider down" }

    ActionAgent::AgentExecutionService.stub(:call, exploding) do
      assert_raises(RuntimeError) { ActionAgent::AgentExecutionJob.perform_now(@run.id) }
      assert @run.reload.failed?

      # A retry of the same job (what retry_on used to do) must be a no-op.
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end

    assert_equal 1, calls
    assert @run.reload.failed?
    assert_equal 1, Array(@run.logs).count { |log| log["message"].to_s.include?("Starting execution") }
  end

  test "a cancel that lands during execution survives the finishing job" do
    cancelling = lambda do |_agent, run|
      run.cancel!
      { output: "finished anyway", metadata: {}, usage: {} }
    end

    ActionAgent::AgentExecutionService.stub(:call, cancelling) do
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end

    @run.reload
    assert @run.cancelled?, "the job flipped a cancelled run to #{@run.status}"
    assert_nil @run.output
  end

  test "a cancel that lands before a failure is not flipped to failed" do
    cancelling = lambda do |_agent, run|
      run.cancel!
      raise "provider down"
    end

    ActionAgent::AgentExecutionService.stub(:call, cancelling) do
      assert_raises(RuntimeError) { ActionAgent::AgentExecutionJob.perform_now(@run.id) }
    end

    assert @run.reload.cancelled?
    assert_equal "Cancelled by user", @run.error_message
  end
end

# Run detail reads its conversation from the context of its own action, not
# whichever context the agent touched last (#378).
class RunConversationTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::AgentMessage.delete_all
    ActionAgent::AgentContext.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  def create_context(action, created_at:)
    ActionAgent::AgentContext.create!(
      contextable: @agent, agent_name: @agent.telemetry_agent_class, action_name: action, created_at: created_at
    )
  end

  test "a run of an older action still finds its messages" do
    run = @agent.agent_runs.create!(input_prompt: "summarize this", status: :complete, action_name: "summarize", trace_id: "trace-summarize")

    older = create_context("summarize", created_at: 2.hours.ago)
    older.add_user_message("summarize this", provenance: { "trace_id" => "trace-summarize" })
    older.add_assistant_message("Here is the summary.")
    newer = create_context("ask", created_at: 1.hour.ago)
    newer.add_user_message("hello", provenance: { "trace_id" => "trace-ask" })

    get "/activeagents/api/runs/#{run.id}"

    assert_response :success
    contents = JSON.parse(response.body)["messages"].map { |message| message["content"] }
    assert_includes contents, "summarize this"
    assert_includes contents, "Here is the summary."
    assert_not_includes contents, "hello"
  end

  test "a run with no action recorded falls back to every context of the agent" do
    run = @agent.agent_runs.create!(input_prompt: "legacy", status: :complete, trace_id: "trace-legacy")
    context = create_context("summarize", created_at: 2.hours.ago)
    context.add_user_message("legacy", provenance: { "trace_id" => "trace-legacy" })
    create_context("ask", created_at: 1.hour.ago)

    get "/activeagents/api/runs/#{run.id}"

    assert_response :success
    assert_includes JSON.parse(response.body)["messages"].map { |m| m["content"] }, "legacy"
  end
end

# Observed agents are read-only until forked (#379).
class ObservedAgentExecutionTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
  end

  test "execute and test refuse a telemetry-observed agent" do
    agent = ActionAgent::Agent.create!(
      name: "Telemetry Only", agent_class_name: "TelemetryOnlyAgent", provider: "openai", model: "unknown", status: :observed
    )

    post "/activeagents/api/agents/#{agent.id}/execute", params: { prompt: "hello" }
    assert_response :unprocessable_entity
    assert_match(/read-only/, JSON.parse(response.body)["error"])

    post "/activeagents/api/agents/#{agent.id}/test", params: { prompt: "hello" }
    assert_response :unprocessable_entity

    assert_equal 0, agent.agent_runs.count, "a refused execution must not leave a failed run on the scorecard"
  end
end
