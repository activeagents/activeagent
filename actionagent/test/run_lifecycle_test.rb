# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# The agent-execution job's terminal states (#377): a failed run is never
# re-executed, and a cancel that lands mid-execution is not overwritten by
# the job that was still running it.
class RunLifecycleTest < ActiveSupport::TestCase
  def setup
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    @run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
    @service_calls = 0
  end

  def counted_service
    lambda do |_agent, _run|
      @service_calls += 1
      { output: "answer", metadata: {}, usage: {} }
    end
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

  test "a run that is already running is not executed again" do
    started_at = 1.hour.ago.change(usec: 0)
    @run.update!(status: :running, started_at: started_at, logs: [ { "message" => "Starting execution" } ])
    ActionAgent::AgentExecutionService.stub(:call, counted_service) do
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end

    @run.reload
    assert_equal 0, @service_calls
    assert @run.running?
    assert_equal started_at, @run.started_at
    assert_equal 1, Array(@run.logs).count { |log| log["message"].to_s.include?("Starting execution") }
  end

  %i[complete cancelled].each do |status|
    test "a #{status} run is left as it is" do
      @run.update!(status: status, started_at: 1.hour.ago, completed_at: 30.minutes.ago, output: "done")
      before = @run.reload.attributes
      ActionAgent::AgentExecutionService.stub(:call, counted_service) do
        ActionAgent::AgentExecutionJob.perform_now(@run.id)
      end

      assert_equal 0, @service_calls
      assert_equal before, @run.reload.attributes
    end
  end

  test "a pending run is claimed once, with its start recorded and announced" do
    calls = 0
    statuses = []
    announced = []
    executing = lambda do |_agent, run|
      calls += 1
      statuses << run.reload.status
      { output: "answer", metadata: {}, usage: {} }
    end
    recording = ->(stream, payload) { announced << payload[:status] if stream == "agent_run_#{@run.id}" }

    ActionAgent::LiveUpdates.stub(:broadcast, recording) do
      ActionAgent::AgentExecutionService.stub(:call, executing) do
        ActionAgent::AgentExecutionJob.perform_now(@run.id)
      end
    end

    @run.reload
    assert_equal 1, calls
    assert_equal %w[running], statuses
    assert_equal "running", announced.first, "subscribers were not told the run started"
    assert @run.complete?
    assert_not_nil @run.started_at
    assert_equal 1, Array(@run.logs).count { |log| log["message"].to_s.include?("Starting execution") }
  end

  test "a run cancelled before its job starts is not started" do
    @run.cancel!
    ActionAgent::AgentExecutionService.stub(:call, counted_service) do
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end

    @run.reload
    assert_equal 0, @service_calls
    assert @run.cancelled?
    assert_nil @run.started_at
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

  # A cancel is decided on a copy of the run loaded earlier: the request's,
  # or a caller's that has held the run since it executed. The run may have
  # finished since then, and a finished run stays as it finished.
  test "a cancel from a copy loaded before the run completed leaves it complete" do
    stale = ActionAgent::AgentRun.find(@run.id)
    ActionAgent::AgentExecutionService.stub(:call, counted_service) do
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end
    before = @run.reload.attributes

    result = stale.cancel!

    assert @run.reload.complete?, "a late cancel flipped a complete run to #{@run.status}"
    assert_equal before, @run.attributes
    assert stale.complete?, "the copy that was cancelled still reads #{stale.status}"
    assert_equal false, result
  end

  test "a cancel from a copy loaded before the run failed keeps the failure" do
    stale = ActionAgent::AgentRun.find(@run.id)
    exploding = ->(_agent, _run) { raise "provider down" }
    ActionAgent::AgentExecutionService.stub(:call, exploding) do
      assert_raises(RuntimeError) { ActionAgent::AgentExecutionJob.perform_now(@run.id) }
    end
    before = @run.reload.attributes

    result = stale.cancel!

    assert @run.reload.failed?, "a late cancel flipped a failed run to #{@run.status}"
    assert_equal "provider down", @run.error_message
    assert_equal before, @run.attributes
    assert_equal false, result
  end

  test "a second cancel keeps the first one's reason and time" do
    stale = ActionAgent::AgentRun.find(@run.id)
    assert_equal true, @run.cancel!("Stopped by the operator")
    before = @run.reload.attributes

    result = travel(1.minute) { stale.cancel! }

    assert_equal "Stopped by the operator", @run.reload.error_message
    assert_equal before, @run.attributes
    assert_equal false, result
    assert_equal false, @run.cancel!, "a cancelled run was cancelled again"
  end

  test "a cancel is announced once, and a cancel that changes nothing is not announced" do
    announced = []
    recording = ->(stream, payload) { announced << payload[:status] if stream == "agent_run_#{@run.id}" }
    stale = ActionAgent::AgentRun.find(@run.id)

    ActionAgent::LiveUpdates.stub(:broadcast, recording) do
      @run.cancel!
      assert_equal %w[cancelled], announced

      announced.clear
      stale.cancel!
      assert_empty announced
    end
  end

  test "a cancel that changes nothing leaves the run's requests for input alone" do
    stale = ActionAgent::AgentRun.find(@run.id)
    @run.update!(status: :failed, completed_at: Time.current, error_message: "expired")
    request = ActionAgent::InputRequest.create!(
      subject: @run, kind: "text", prompt: "Where to?", tool_call_id: "call_1", pause_key: "pause_1", status: :pending
    )

    stale.cancel!

    assert request.reload.pending?
  end
end

# Two workers that receive the same job at once (a queue delivering it twice,
# or a redelivery after a visibility timeout) have both read the run as
# pending before either writes. Real connections are needed to see it, so the
# test does not run inside a transaction, and it removes the rows it commits.
# Both workers are held at the run's lookup until each has it, which makes the
# interleaving certain instead of likely.
class RunClaimConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
    @run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
  end

  # The agent's runs and versions go with it (dependent: :destroy).
  def teardown
    ActionAgent::Agent.find_by(id: @agent&.id)&.destroy!
  end

  test "two workers that load the same pending run execute it once" do
    lookup = ActionAgent::AgentRun.method(:find)
    barrier = Concurrent::CyclicBarrier.new(2)
    loaded_together = lambda do |id|
      run = lookup.call(id)
      barrier.wait(10)
      run
    end
    calls = Concurrent::AtomicFixnum.new(0)
    executing = lambda do |_agent, _run|
      calls.increment
      { output: "answer", metadata: {}, usage: {} }
    end

    ActionAgent::AgentRun.stub(:find, loaded_together) do
      ActionAgent::AgentExecutionService.stub(:call, executing) do
        workers = Array.new(2) do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              ActionAgent::AgentExecutionJob.perform_now(@run.id)
            end
          end
        end
        workers.each(&:join)
      end
    end

    @run.reload
    assert_equal 1, calls.value, "the run was executed by both workers"
    assert @run.complete?
    assert_equal 1, Array(@run.logs).count { |log| log["message"].to_s.include?("Starting execution") }
  end

  # Another worker process has claimed the run and not yet committed when
  # this worker's job claims it; it commits a moment later. The job waits
  # for that commit and then declines. A read under the row lock followed by
  # a write cannot do that on SQLite with Rails 7.2, whose deferred
  # transactions refuse the write once the other process has committed
  # ("database is locked"). The other worker is a forked process, as job
  # workers are, so it commits whatever this process is blocked on; how long
  # it holds the claim decides only whether the job meets it in flight.
  test "a worker that finds another worker's claim in flight starts no generation" do
    reader, writer = IO.pipe
    claimant = fork do
      reader.close
      ActiveRecord::Base.establish_connection
      run = ActionAgent::AgentRun.find(@run.id)
      run.with_lock do
        run.update!(status: :running, started_at: Time.current)
        writer.puts("held")
        writer.flush
        sleep 0.3
      end
      exit!(0)
    rescue Exception # rubocop:disable Lint/RescueException
      exit!(1)
    end
    writer.close
    assert_equal "held", reader.gets(chomp: true), "the other worker did not claim the run"

    calls = 0
    ActionAgent::AgentExecutionService.stub(:call, ->(_agent, _run) { calls += 1 }) do
      ActionAgent::AgentExecutionJob.perform_now(@run.id)
    end

    Process.wait(claimant)
    assert_predicate $?, :success?, "the other worker failed to claim the run"
    assert_equal 0, calls
    assert @run.reload.running?
    assert_empty Array(@run.logs)
  ensure
    reader&.close
  end
end

# A cancel request and the job finishing the run, each on its own connection
# as a web process and a worker are. Not inside a transaction, so each sees
# what the other committed; the test removes the rows it commits.
class RunCancelConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "openai", model: "gpt-4o-mini")
  end

  # The agent's runs and versions go with it (dependent: :destroy).
  def teardown
    ActionAgent::Agent.find_by(id: @agent&.id)&.destroy!
  end

  def finishing_service
    ->(_agent, _run) { { output: "answer", metadata: {}, usage: {} } }
  end

  # The cancel loads the run while it is running and writes only after the
  # worker has committed its result, which is the order a slow cancel
  # request meets a fast generation in.
  test "a cancel that loaded the run while it ran does not overwrite the worker's result" do
    run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
    loaded = Concurrent::Event.new
    finished = Concurrent::Event.new
    cancel_result = nil

    cancelling = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        stale = ActionAgent::AgentRun.find(run.id)
        loaded.set
        finished.wait(10)
        cancel_result = stale.cancel!
      end
    end
    held_until_loaded = lambda do |agent, executing|
      loaded.wait(10)
      finishing_service.call(agent, executing)
    end
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActionAgent::AgentExecutionService.stub(:call, held_until_loaded) do
          ActionAgent::AgentExecutionJob.perform_now(run.id)
        end
      ensure
        finished.set
      end
    end
    [ worker, cancelling ].each(&:join)

    run.reload
    assert run.complete?, "the late cancel left the run #{run.status}"
    assert_equal "answer", run.output
    assert_nil run.error_message
    assert_equal false, cancel_result
  end

  # Released together, either may write first. Whichever wins, the run ends
  # in one consistent state: complete with the worker's output, or cancelled
  # without it. Never cancelled with the output a finished worker recorded.
  #
  # The worker records under unless_cancelled, a read under the row lock
  # followed by a write. On SQLite under Rails 7.2, whose transactions are
  # deferred, that write is refused ("database is locked") when the cancel
  # commits between the two; the worker then records nothing, which leaves
  # the run as the cancel left it. Rails 8 takes the write lock first, so
  # the cancel waits for the worker instead.
  test "a cancel racing the finishing worker leaves one consistent outcome" do
    10.times do
      run = @agent.agent_runs.create!(input_prompt: "hi", status: :pending)
      ActionAgent::AgentRun.where(id: run.id).update_all(status: ActionAgent::AgentRun.statuses[:running], started_at: Time.current)
      barrier = Concurrent::CyclicBarrier.new(2)

      cancelling = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          stale = ActionAgent::AgentRun.find(run.id)
          barrier.wait(10)
          stale.cancel!
        end
      end
      finishing = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          executing = ActionAgent::AgentRun.find(run.id)
          barrier.wait(10)
          executing.unless_cancelled do
            executing.record_result!(finishing_service.call(nil, executing), segment_started_at: executing.started_at)
          end
        rescue ActiveRecord::StatementInvalid => e
          raise unless e.cause.is_a?(SQLite3::BusyException)

          :refused
        end
      end
      cancelling.join
      refused = finishing.value == :refused

      run.reload
      assert run.cancelled?, "the worker's write was refused, yet the run is #{run.status}" if refused
      if run.cancelled?
        assert_nil run.output, "a cancelled run kept the finished worker's output"
      else
        assert run.complete?, "the race left the run #{run.status}"
        assert_nil run.error_message, "a complete run carries the cancel's reason"
      end
    end
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
  TelemetryTraceTest.ensure_table!

  def setup
    ActionAgent::AgentMessage.delete_all
    ActionAgent::AgentContext.delete_all
    ActionAgent::AgentRun.delete_all
    ActionAgent::Agent.delete_all
  end

  def observed_agent_with_reported_turn
    agent = ActionAgent::Agent.create!(name: "External support", provider: "mock", model: "support", status: :observed)
    context = ActionAgent::AgentContext.create!(
      contextable: agent, agent_name: agent.telemetry_agent_class, action_name: "ask"
    )
    [ agent, context, context.add_assistant_message("Order ABC-123 shipped on Tuesday.") ]
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

  test "observed agents cannot be changed into executable agents or restored through the API" do
    agent = ActionAgent::Agent.create!(name: "External support", provider: "mock", model: "support", status: :observed)
    version = agent.latest_version

    patch "/activeagents/api/agents/#{agent.id}", params: { agent: { status: "active", instructions: "Changed" } }, as: :json
    assert_response :unprocessable_entity
    assert agent.reload.observed?
    assert_nil agent.instructions
    post "/activeagents/api/agents/#{agent.id}/restore", params: { version_id: version.id }, as: :json
    assert_response :unprocessable_entity
    assert_equal 1, agent.agent_versions.count

    post "/activeagents/api/agents/#{agent.id}/duplicate", as: :json
    assert_response :created
    copy = ActionAgent::Agent.find(JSON.parse(response.body).dig("agent", "id"))
    assert copy.draft?
    refute_equal agent.id, copy.id
    post "/activeagents/api/agents/#{copy.id}/execute", params: { prompt: "Find order ABC-123" }, as: :json
    assert_response :accepted
    assert_equal 1, copy.agent_runs.count
    assert_equal 0, agent.agent_runs.count
  end

  test "direct observed agent execution cannot create a run" do
    agent = ActionAgent::Agent.create!(name: "External support", provider: "mock", model: "support", status: :observed)

    assert_no_difference "ActionAgent::AgentRun.count" do
      assert_raises(ActionAgent::Agent::ObservedAgentError) { agent.execute("Find order ABC-123") }
      assert_raises(ActionAgent::Agent::ObservedAgentError) { agent.test_execute("Find order ABC-123") }
    end
  end

  test "a queued execution fails without a provider call when its agent becomes observed" do
    agent = ActionAgent::Agent.create!(name: "External support", provider: "mock", model: "support")
    run = agent.agent_runs.create!(input_prompt: "Find order ABC-123", status: :pending)
    agent.update!(status: :observed)

    assert_no_difference "ActionAgent::TelemetryTrace.count" do
      assert_raises(ActionAgent::Agent::ObservedAgentError) { ActionAgent::AgentExecutionJob.perform_now(run.id) }
    end
    assert run.reload.failed?
    assert_match(/read-only/, run.error_message)
  end

  # The runner's conversation workbench writes an agent's history without
  # running it (#405): a context, and turns typed into it. Same policy as
  # execution — an observed agent is a telemetry mirror, so a fabricated
  # assistant turn attributed to it is history we have no business authoring.
  # The two gates are separate controllers, so they get separate tests: one
  # reopening without the other has to fail visibly.
  test "starting a conversation refuses a telemetry-observed agent" do
    agent, _context, _reported = observed_agent_with_reported_turn

    post "/activeagents/api/agents/#{agent.id}/conversations", as: :json

    assert_response :unprocessable_entity
    assert_match(/read-only/, JSON.parse(response.body)["error"])
    assert_equal 1, ActionAgent::AgentContext.where(contextable: agent).count
  end

  test "writing a turn refuses a telemetry-observed agent" do
    _agent, context, reported = observed_agent_with_reported_turn
    base = "/activeagents/api/interactions/#{context.id}/messages"

    post base, params: { role: "assistant", content: "We can refund that for you." }, as: :json
    assert_response :unprocessable_entity
    assert_match(/read-only/, JSON.parse(response.body)["error"])

    patch "#{base}/#{reported.id}", params: { content: "Rewritten" }, as: :json
    assert_response :unprocessable_entity

    delete "#{base}/#{reported.id}", as: :json
    assert_response :unprocessable_entity

    assert_equal [ "Order ABC-123 shipped on Tuesday." ], context.messages.reload.map(&:content)
  end

  test "an observed agent's conversations stay readable" do
    agent, context, _reported = observed_agent_with_reported_turn

    get "/activeagents/api/agents/#{agent.id}/conversations"

    assert_response :success
    rows = JSON.parse(response.body)["conversations"]
    assert_equal [ context.id ], rows.map { |row| row["id"] }

    get "/activeagents/api/interactions/#{context.id}"
    assert_response :success
  end

  test "conversations of an executable agent are unaffected" do
    agent = ActionAgent::Agent.create!(name: "Support", provider: "mock", model: "mock", status: :active)

    post "/activeagents/api/agents/#{agent.id}/conversations", as: :json

    assert_response :created
    context = ActionAgent::AgentContext.find(JSON.parse(response.body).dig("conversation", "id"))
    base = "/activeagents/api/interactions/#{context.id}/messages"

    post base, params: { role: "assistant", content: "Seeded reply" }, as: :json
    assert_response :created
    message_id = JSON.parse(response.body).dig("message", "id")

    patch "#{base}/#{message_id}", params: { content: "Edited reply" }, as: :json
    assert_response :success
    assert_equal "Edited reply", ActionAgent::AgentMessage.find(message_id).content

    delete "#{base}/#{message_id}", as: :json
    assert_response :no_content
    assert_equal 0, context.messages.count
  end
end
