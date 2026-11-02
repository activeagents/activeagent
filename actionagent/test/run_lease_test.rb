# frozen_string_literal: true

require "test_helper"

# Every claim of a run for an execution segment takes a lease: a token of
# its own and an expiry, renewed by each LLM or tool call the run makes.
class RunLeaseTest < ActiveSupport::TestCase
  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    @run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
  end

  def answer
    { output: "answer", metadata: {}, usage: {} }
  end

  # Records the run's lease as the generation sees it, from the database.
  def lease_seen(into)
    lambda do |_agent, run, **|
      into << ActionAgent::AgentRun.where(id: run.id).pick(:execution_token, :execution_expires_at)
      answer
    end
  end

  def paused_run(token: "segment-1")
    @run.update!(status: :awaiting_input, started_at: 1.minute.ago, execution_token: token)
    ActionAgent::InputRequest.create!(
      subject: @run, kind: "text", prompt: "Where to?", tool_call_id: "call_1", pause_key: "pause_1",
      status: :answered, answer: "Lisbon", checkpoint: "{}"
    )
  end

  test "the execution job's claim takes a lease for the run" do
    seen = []
    freeze_time do
      ActionAgent::AgentExecutionService.stub(:call, lease_seen(seen)) do
        ActionAgent::AgentExecutionJob.perform_now(@run.id)
      end

      token, expires_at = seen.sole
      assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, token)
      assert_equal 30.minutes.from_now, expires_at
    end
  end

  test "a resumed segment takes a lease under a new token" do
    request = paused_run(token: "segment-1")
    seen = []
    ActionAgent::AgentExecutionService.stub(:call, lease_seen(seen)) do
      ActionAgent::AgentResumeJob.perform_now(request.id)
    end

    token, expires_at = seen.sole
    assert token.present?
    assert_not_equal "segment-1", token
    assert_in_delta 30.minutes.from_now, expires_at, 5.seconds
  end

  test "a synchronous test run is created under a lease" do
    seen = []
    ActionAgent::AgentExecutionService.stub(:call, lease_seen(seen)) do
      @agent.test_execute("hi")
    end

    token, expires_at = seen.sole
    assert token.present?
    assert_in_delta 30.minutes.from_now, expires_at, 5.seconds
  end

  test "two claims never share a token" do
    other = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
    seen = []
    ActionAgent::AgentExecutionService.stub(:call, lease_seen(seen)) do
      [ @run, other ].each { |run| ActionAgent::AgentExecutionJob.perform_now(run.id) }
    end

    assert_equal 2, seen.map(&:first).uniq.size
  end

  test "a progress event renews the lease of the run it belongs to" do
    @run.update!(status: :running, execution_token: "mine", execution_expires_at: 1.minute.from_now)

    freeze_time do
      @run.append_event(eid: "e1", kind: :llm, label: "gpt-4o-mini", status: "started")

      assert_equal 30.minutes.from_now, @run.reload.execution_expires_at
    end
  end

  test "a renewal leaves a run that is not running under the copy's token alone" do
    copy = ActionAgent::AgentRun.find(@run.id)
    copy.execution_token = "mine"
    expires_at = 1.minute.from_now.change(usec: 0)

    { "theirs" => :running, "mine" => :complete }.each do |token, status|
      @run.update!(status: status, execution_token: token, execution_expires_at: expires_at)

      assert_equal false, copy.renew_lease!
      assert_equal expires_at, @run.reload.execution_expires_at
    end
  end

  test "no lease is taken without a lease duration" do
    seen = []
    with_lease_duration(nil) do
      ActionAgent::AgentExecutionService.stub(:call, lease_seen(seen)) do
        ActionAgent::AgentExecutionJob.perform_now(@run.id)
      end
    end

    assert_equal [ [ nil, nil ] ], seen
    assert @run.reload.complete?
  end

  test "no lease is taken before migration 033 has run" do
    seen = []
    ActionAgent::AgentRun.stub(:execution_leases?, false) do
      ActionAgent::AgentExecutionService.stub(:call, lease_seen(seen)) do
        ActionAgent::AgentExecutionJob.perform_now(@run.id)
      end
      @run.update_columns(status: ActionAgent::AgentRun.statuses[:running], execution_token: "mine")

      assert_equal false, @run.renew_lease!
    end

    assert_equal [ [ nil, nil ] ], seen
  end

  def with_lease_duration(duration)
    previous = ActionAgent.run_lease_duration
    ActionAgent.run_lease_duration = duration
    yield
  ensure
    ActionAgent.run_lease_duration = previous
  end
end
