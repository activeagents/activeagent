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

# A worker records its segment's result only while the run is still running
# under the token its claim took. Whatever ended the run under it, or took
# it for another segment, wins over the late result.
class RunLeaseFenceTest < ActiveSupport::TestCase
  WorkerLost = Class.new(StandardError) { def self.name = "WorkerLost" }

  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    @run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
  end

  # A generation during which something else fails the run, as a sweeper
  # that took the worker for lost would. Returns +outcome+'s result.
  def failed_under_it(outcome = -> { { output: "late answer", metadata: {}, usage: {} } })
    lambda do |_agent, run, **|
      ActionAgent::AgentRun.find(run.id).record_failure!(WorkerLost.new("lease expired"))
      outcome.call
    end
  end

  def discarded?(run)
    Array(run.logs).any? { |log| log["message"].to_s.include?("ended or taken by another worker; result discarded") }
  end

  test "a worker whose run was ended under it does not record its result" do
    ActionAgent::AgentExecutionService.stub(:call, failed_under_it) do
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end

    @run.reload
    assert @run.failed?, "the late result turned the run #{@run.status}"
    assert_nil @run.output
    assert_equal "lease expired", @run.error_message
    assert_equal "WorkerLost", @run.output_metadata["error_class"]
    assert discarded?(@run)
  end

  test "a worker whose run was ended under it does not record its own failure" do
    exploding = failed_under_it(-> { raise "provider down" })
    ActionAgent::AgentExecutionService.stub(:call, exploding) do
      assert_raises(RuntimeError) { ActionAgent::AgentExecutionJob.perform_now(@run.id) }
    end

    assert_equal "lease expired", @run.reload.error_message
    assert discarded?(@run)
  end

  test "a resumed segment whose run was ended under it does not record its result" do
    @run.update!(status: :awaiting_input, started_at: 1.minute.ago)
    request = ActionAgent::InputRequest.create!(
      subject: @run, kind: "text", prompt: "Where to?", tool_call_id: "call_1", pause_key: "pause_1",
      status: :answered, answer: "Lisbon", checkpoint: "{}"
    )

    ActionAgent::AgentExecutionService.stub(:call, failed_under_it) do
      ActionAgent::AgentResumeJob.perform_now(request.id)
    end

    @run.reload
    assert @run.failed?
    assert_nil @run.output
  end

  test "a synchronous test run that was ended under it does not record its result" do
    run = nil
    ActionAgent::AgentExecutionService.stub(:call, failed_under_it) do
      run = @agent.test_execute("hi")
    end

    assert run.reload.failed?
    assert_nil run.output
    assert_equal "lease expired", run.error_message
  end

  test "a synchronous test run that was ended under it does not record its own failure" do
    run = nil
    ActionAgent::AgentExecutionService.stub(:call, failed_under_it(-> { raise "provider down" })) do
      run = @agent.test_execute("hi")
    end

    assert run.reload.failed?
    assert_equal "lease expired", run.error_message
  end

  test "a synchronous test run cancelled while it ran stays cancelled, as a job's run does" do
    cancelling = lambda do |_agent, run, **|
      ActionAgent::AgentRun.find(run.id).cancel!
      { output: "finished anyway", metadata: {}, usage: {} }
    end
    run = nil
    ActionAgent::AgentExecutionService.stub(:call, cancelling) do
      run = @agent.test_execute("hi")
    end

    assert run.reload.cancelled?
    assert_nil run.output
  end

  test "a worker whose run was taken under another token does not record its result" do
    retaken = lambda do |_agent, run, **|
      ActionAgent::AgentRun.where(id: run.id).update_all(execution_token: "another-segment")
      { output: "late answer", metadata: {}, usage: {} }
    end
    ActionAgent::AgentExecutionService.stub(:call, retaken) do
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end

    @run.reload
    assert @run.running?
    assert_equal "another-segment", @run.execution_token
    assert_nil @run.output
  end

  test "a segment that ends releases its lease, whether it completed, paused or failed" do
    outcomes = {
      complete: { output: "answer", metadata: {}, usage: {} },
      awaiting_input: { output: nil, metadata: {}, usage: {}, checkpoint: { "messages" => [] },
                        input_requests: [ ActiveAgent::InputRequest.text("Where to?").with(tool_call_id: "call_1", tool_name: "ask_user") ] },
      failed: -> { raise "provider down" }
    }
    outcomes.each do |status, outcome|
      run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
      held = nil
      service = lambda do |_agent, executing, **|
        held = ActionAgent::AgentRun.where(id: executing.id).pick(:execution_token)
        outcome.respond_to?(:call) ? outcome.call : outcome
      end
      ActionAgent::AgentExecutionService.stub(:call, service) do
        ActionAgent::AgentExecutionJob.perform_now(run.id)
      rescue RuntimeError
        nil
      end

      run.reload
      assert held.present?, "the #{status} segment ran without a lease"
      assert_equal status.to_s, run.status
      assert_nil run.execution_token, "a #{status} run kept its lease token"
      assert_nil run.execution_expires_at
    end
  end
end

# The worker is slow, not dead: it is still in its generation, on its own
# connection, when the run is failed as lost on another. Not transactional,
# so each sees what the other committed; the agent and its runs are removed.
class RunLeaseLateWorkerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    @run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
  end

  def teardown
    ActionAgent::Agent.find_by(id: @agent&.id)&.destroy!
  end

  test "a late worker's result does not overwrite a run failed as lost meanwhile" do
    started = Concurrent::Event.new
    release = Concurrent::Event.new
    held = lambda do |_agent, _run, **|
      started.set
      release.wait(10)
      { output: "late answer", metadata: {}, usage: {} }
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActionAgent::AgentExecutionService.stub(:call, held) do
          ActionAgent::AgentExecutionJob.perform_now(@run.id)
        end
      end
    end
    assert started.wait(10), "the worker never started its generation"

    lost = Class.new(StandardError) { def self.name = "WorkerLost" }
    ActionAgent::AgentRun.find(@run.id).record_failure!(lost.new("lease expired"))
    release.set
    worker.join

    @run.reload
    assert @run.failed?, "the late worker turned the run #{@run.status}"
    assert_nil @run.output
    assert_equal "lease expired", @run.error_message
  end
end
