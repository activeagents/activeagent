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

# A running run whose lease ran out is failed as lost, once, and never
# executed again. Its page, the run list and AgentRunExpiryJob find it.
class RunLeaseExpiryTest < ActionDispatch::IntegrationTest
  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  def leased_run(status: :running, expires_at: 1.minute.ago, token: "lost-worker", **attributes)
    @agent.agent_runs.create!(
      input_prompt: "hi", status: status, started_at: 1.hour.ago,
      execution_token: token, execution_expires_at: expires_at, **attributes
    )
  end

  def announcements(run)
    seen = []
    recording = ->(stream, payload) { seen << payload[:status] if stream == "agent_run_#{run.id}" }
    ActionAgent::LiveUpdates.stub(:broadcast, recording) { yield }
    seen
  end

  test "a running run past its lease is failed as lost, once, and announced once" do
    run = leased_run(output_metadata: { "provider" => "openai" })

    announced = announcements(run) do
      assert_equal true, run.expire_if_lost!
      assert_equal false, run.expire_if_lost!
    end

    run.reload
    assert run.failed?
    assert_equal({ "provider" => "openai", "error_class" => "ActionAgent::AgentRun::WorkerLost" }, run.output_metadata)
    assert_match(/stopped reporting progress.*not executed again/, run.error_message)
    assert_not_nil run.completed_at
    assert_nil run.execution_token
    assert_nil run.execution_expires_at
    assert_equal %w[failed], announced
    assert_equal 1, Array(run.logs).count { |log| log["message"].to_s.include?("stopped reporting progress") }
  end

  test "a lost run is not executed again" do
    run = leased_run
    calls = 0
    ActionAgent::AgentExecutionService.stub(:call, ->(*) { calls += 1 }) do
      assert_no_enqueued_jobs { ActionAgent::AgentRunExpiryJob.perform_now }
      ActionAgent::AgentExecutionJob.perform_now(run.id)
    end

    assert_equal 0, calls
    assert run.reload.failed?
  end

  test "a run within its lease, or renewed since it was read, is left running" do
    live = leased_run(expires_at: 1.minute.from_now)
    renewed = leased_run
    stale = ActionAgent::AgentRun.find(renewed.id)
    renewed.renew_lease!

    # The run's page checks on every read: a run within its lease costs no query.
    assert_no_queries { assert_equal false, live.expire_if_lost! }
    assert_equal false, stale.expire_if_lost!
    assert live.reload.running?
    assert renewed.reload.running?
  end

  test "a run taken for a new segment since it was read is left to that segment" do
    run = leased_run
    stale = ActionAgent::AgentRun.find(run.id)
    run.update!(execution_token: "next-segment")

    assert_equal false, stale.expire_if_lost!
    assert run.reload.running?
    assert stale.running?, "the copy was not reloaded"
  end

  test "only running runs are expired, whatever their lease columns say" do
    others = %i[pending complete failed cancelled awaiting_input].map { |status| leased_run(status: status) }
    before = others.map { |run| run.reload.attributes }

    assert_equal 0, ActionAgent::AgentRun.expire_lost!

    assert_equal before, others.map { |run| run.reload.attributes }
  end

  test "a run without a lease, such as one started before migration 033, is never expired" do
    run = leased_run(token: nil, expires_at: nil)

    assert_empty ActionAgent::AgentRun.lost
    assert_equal 0, ActionAgent::AgentRun.expire_lost!
    assert_equal false, run.expire_if_lost!
    assert run.reload.running?
  end

  test "nothing is expired without the lease columns" do
    run = leased_run
    ActionAgent::AgentRun.stub(:execution_leases?, false) do
      ActionAgent::AgentRun.stub(:lost, ->(*) { flunk "queried the lease columns a host has not migrated" }) do
        assert_equal 0, ActionAgent::AgentRun.expire_lost!
      end
      assert_equal false, run.expire_if_lost!
    end

    assert run.reload.running?
  end

  test "a cancel that lands first wins over the expiry" do
    run = leased_run
    stale = ActionAgent::AgentRun.find(run.id)
    run.cancel!

    assert_equal false, stale.expire_if_lost!
    assert run.reload.cancelled?
  end

  test "AgentRunExpiryJob fails every lost run, and only those" do
    lost = [ leased_run, leased_run(token: "other-lost-worker") ]
    live = leased_run(expires_at: 5.minutes.from_now)

    ActionAgent::AgentRunExpiryJob.perform_now

    assert lost.all? { |run| run.reload.failed? }
    assert live.reload.running?
  end

  test "a lost run's page shows it failed" do
    run = leased_run

    get "/activeagents/api/runs/#{run.id}"

    assert_response :success
    assert_equal "failed", JSON.parse(response.body).dig("run", "status")
  end

  test "the run list shows a lost run failed" do
    run = leased_run

    get "/activeagents/api/runs"

    assert_response :success
    listed = JSON.parse(response.body)["runs"].find { |entry| entry["id"] == run.id }
    assert_equal "failed", listed["status"]
  end

  test "a worker that finishes after its run was failed as lost has its result discarded" do
    run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
    outlived = lambda do |_agent, _run, **|
      travel(31.minutes) { ActionAgent::AgentRunExpiryJob.perform_now }
      { output: "late answer", metadata: {}, usage: {} }
    end
    ActionAgent::AgentExecutionService.stub(:call, outlived) do
      ActionAgent::AgentExecutionJob.perform_now(run.id)
    end

    run.reload
    assert run.failed?
    assert_nil run.output
    assert_equal "ActionAgent::AgentRun::WorkerLost", run.output_metadata["error_class"]
  end

  test "a healthy run whose progress renews its lease outlasts the lease duration" do
    run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
    steady = lambda do |_agent, executing, **|
      3.times do |step|
        travel(20.minutes)
        executing.append_event(eid: "e#{step}", kind: :llm, label: "gpt-4o-mini")
        ActionAgent::AgentRunExpiryJob.perform_now
      end
      { output: "answer", metadata: {}, usage: {} }
    end
    ActionAgent::AgentExecutionService.stub(:call, steady) do
      ActionAgent::AgentExecutionJob.perform_now(run.id)
    end

    assert run.reload.complete?, "a run that kept reporting progress was taken for lost"
    assert_equal "answer", run.output
  ensure
    travel_back
  end
end

# Two sweeps reach the same lost run at once, each on its own connection.
class RunLeaseExpiryConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  def teardown
    ActionAgent::Agent.find_by(id: @agent&.id)&.destroy!
  end

  test "two sweeps that load the same lost run fail it once" do
    run = @agent.agent_runs.create!(
      input_prompt: "hi", status: :running, started_at: 1.hour.ago,
      execution_token: "lost-worker", execution_expires_at: 1.minute.ago
    )
    barrier = Concurrent::CyclicBarrier.new(2)
    announced = Concurrent::Array.new
    recording = ->(stream, payload) { announced << payload[:status] if stream == "agent_run_#{run.id}" }

    results = ActionAgent::LiveUpdates.stub(:broadcast, recording) do
      Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            copy = ActionAgent::AgentRun.find(run.id)
            barrier.wait(10)
            copy.expire_if_lost!
          end
        end
      end.map(&:value)
    end

    assert_equal [ false, true ], results.sort_by { |result| result ? 1 : 0 }
    assert_equal %w[failed], announced.to_a
    assert_equal 1, Array(run.reload.logs).count { |log| log["message"].to_s.include?("stopped reporting progress") }
  end
end
