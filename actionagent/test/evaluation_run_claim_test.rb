# frozen_string_literal: true

require "test_helper"

# An evaluation run created ahead of time (Evaluation#run_later!) is executed
# by the EvaluationRunJob delivered for it. A job delivered again, or one the
# queue hands to a second worker, must not replay the suite a second time:
# every replay is a billed provider call and may call the agent's tools.
module EvaluationRunClaimHelpers
  def build_suite
    agent = ActionAgent::Agent.create!(name: "Claim Agent", provider: "mock", model: "mock-model", instructions: "Answer with the data.")
    evaluation = agent.evaluations.new(
      name: "Support questions",
      judge_kind: "rules",
      criteria: [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
    )
    evaluation.scenarios.build(key: "tickets_1", group: "Tickets", prompt: "Which open tickets mention a refund?")
    evaluation.scenarios.build(key: "tickets_2", group: "Tickets", prompt: "Show me all tickets with no assignee")
    evaluation.scenarios.build(key: "history_1", group: "History", prompt: "Who changed the shipping policy last week?")
    evaluation.save!
    evaluation
  end

  # Runs the block with every replay answered without the agent, counting
  # the replays in +calls+.
  def counting_replays(calls)
    klass = ActionAgent::ScenarioEvaluationRunner
    original = klass.instance_method(:replay)
    klass.define_method(:replay) do |_scenario, _spec|
      calls.increment
      ActiveAgent::Evals::Replay.new(answer: "The data.", duration_ms: 1)
    end
    yield
  ensure
    klass.define_method(:replay, original)
  end

  def with_fan_out(value)
    previous = ActionAgent.scenario_evaluation_fan_out
    ActionAgent.scenario_evaluation_fan_out = value
    yield
  ensure
    ActionAgent.scenario_evaluation_fan_out = previous
  end
end

class EvaluationRunClaimTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include EvaluationRunClaimHelpers

  def setup
    ActionAgent::Agent.delete_all
  end

  test "a pending run is executed once and completed" do
    evaluation = build_suite
    run = evaluation.run_later!
    calls = Concurrent::AtomicFixnum.new(0)

    counting_replays(calls) { perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob) }

    assert_equal 3, calls.value
    assert_equal "complete", run.reload.status
    assert_equal 3, run.scenario_results.count
  end

  test "a job delivered again for a run already running replays nothing" do
    evaluation = build_suite
    run = evaluation.evaluation_runs.create!(status: :running)
    calls = Concurrent::AtomicFixnum.new(0)

    counting_replays(calls) { ActionAgent::EvaluationRunJob.perform_now(evaluation.id, run.id, {}) }

    assert_equal 0, calls.value
    assert_equal "running", run.reload.status
  end

  %w[complete failed].each do |status|
    test "a job delivered again for a #{status} run leaves it #{status}" do
      evaluation = build_suite
      run = evaluation.evaluation_runs.create!(status: status, error_message: "kept", completed_at: 1.hour.ago)
      calls = Concurrent::AtomicFixnum.new(0)

      counting_replays(calls) { ActionAgent::EvaluationRunJob.perform_now(evaluation.id, run.id, {}) }

      assert_equal 0, calls.value
      run.reload
      assert_equal status, run.status
      assert_equal "kept", run.error_message
    end
  end

  # A copy loaded while the run was still pending, as a second worker holds
  # it, does not start the run once another worker has claimed it.
  test "a runner handed a stale pending copy of a claimed run replays nothing" do
    evaluation = build_suite
    run = evaluation.evaluation_runs.create!(status: :pending)
    stale = evaluation.evaluation_runs.find(run.id)
    run.update!(status: :running)
    calls = Concurrent::AtomicFixnum.new(0)

    counting_replays(calls) { evaluation.run!(run: stale) }

    assert_equal 0, calls.value
    assert_equal "running", run.reload.status
    assert_empty run.scenario_results
  end

  # The run records the failure instead of staying pending forever: the
  # selection is read after the run is claimed, so its error fails the run.
  # A model handed back whole (a re-run of a stored spec) keeps the provider
  # it names, which is how an unsupported one reaches the runner.
  test "a pending run whose models cannot be resolved fails rather than staying pending" do
    evaluation = build_suite
    run = evaluation.run_later!(models: [ { "provider" => "nowhere", "model" => "model-x" } ])

    assert_raises(ArgumentError) { perform_enqueued_jobs(only: ActionAgent::EvaluationRunJob) }

    run.reload
    assert_equal "failed", run.status
    assert_match(/unsupported model provider/, run.error_message)
    assert_not_nil run.completed_at
  end
end

# Two workers that receive the same EvaluationRunJob at once have both read
# the run as pending before either writes. Real connections are needed to
# see it, so the test does not run inside a transaction, and it removes the
# rows it commits. Both workers are held right after loading the run until
# each has it, which makes the interleaving certain instead of likely.
class EvaluationRunClaimConcurrencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include EvaluationRunClaimHelpers

  self.use_transactional_tests = false

  def setup
    @evaluation = build_suite
  end

  # The evaluation, its runs, results and scenarios go with the agent.
  def teardown
    ActionAgent::Agent.find_by(id: @evaluation&.agent_id)&.destroy!
  end

  # Each worker's evaluation hands out its runs through this, which waits
  # for the other worker once the run is loaded.
  class RunsLoadedTogether < SimpleDelegator
    def initialize(runs, barrier)
      super(runs)
      @barrier = barrier
    end

    def find(*args)
      __getobj__.find(*args).tap do
        @barrier&.wait(10)
        @barrier = nil
      end
    end
  end

  def two_workers_at_once(run)
    lookup = ActionAgent::Evaluation.method(:find)
    barrier = Concurrent::CyclicBarrier.new(2)
    loaded_together = lambda do |id|
      evaluation = lookup.call(id)
      runs = RunsLoadedTogether.new(evaluation.evaluation_runs, barrier)
      evaluation.define_singleton_method(:evaluation_runs) { runs }
      evaluation
    end
    errors = Queue.new

    ActionAgent::Evaluation.stub(:find, loaded_together) do
      workers = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ActionAgent::EvaluationRunJob.perform_now(@evaluation.id, run.id, {})
          end
        rescue StandardError => e
          errors << e
        end
      end
      workers.each(&:join)
    end
    assert_empty Array.new(errors.size) { errors.pop }, "a worker raised"
  end

  test "two workers that load the same pending run replay the suite once" do
    run = @evaluation.evaluation_runs.create!(status: :pending)
    calls = Concurrent::AtomicFixnum.new(0)

    with_fan_out(false) do
      counting_replays(calls) { two_workers_at_once(run) }
    end

    run.reload
    assert_equal 3, calls.value, "the suite was replayed by both workers"
    assert_equal "complete", run.status
    assert_equal 3, run.scenario_results.count
  end

  test "two workers that load the same pending fanned-out run enqueue its replays once" do
    run = @evaluation.evaluation_runs.create!(status: :pending)

    with_fan_out(true) { two_workers_at_once(run) }

    replays = enqueued_jobs.select { |job| job["job_class"] == "ActionAgent::EvaluationReplayJob" }
    assert_equal 3, replays.size, "both workers fanned the run out"
    assert_equal "running", run.reload.status
  end
end
