# frozen_string_literal: true

require "test_helper"

# Who a run is for, and how that reaches a tool.
#
# The dashboard already had the authorization seam on the tool side — a
# SchemaTools `scope` block takes an `actor:` — but nothing ever filled it, so
# every run executed unattributed and a correctly written host scope returned
# the empty set. These cover the wiring that fills it, and the two ways it
# could be forged if the actor were just another argument.
class AgentAuthorizationTest < ActiveSupport::TestCase
  # Records what it was called with, so a test can assert on the actor a tool
  # saw rather than on a relation the dummy app would have to provide.
  class RecordingTools
    class << self
      attr_accessor :calls

      def model = ActionAgent::Agent
      def tool_names = [ "find_records" ]
      def tool?(name) = tool_names.include?(name.to_s)

      def tool_definitions
        [ { name: "find_records", description: "Finds records.", parameters: {} } ]
      end

      def call(name, actor: nil, **arguments)
        (self.calls ||= []) << { name: name, actor: actor, arguments: arguments }
        { results: [], actor: actor.respond_to?(:id) ? actor.id : actor }
      end
    end
  end

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::AgentRun.delete_all
    RecordingTools.calls = []
    ActionAgent.schema_tools = [ RecordingTools ]
  end

  def teardown
    ActionAgent.schema_tools = nil
    ActionAgent.agent_actor_resolver = nil
  end

  def create_agent(**attributes)
    ActionAgent::Agent.create!(
      { name: "Records", provider: "mock", model: "mock", tools: [ "find_records" ] }.merge(attributes)
    )
  end

  # --- the seam is filled ------------------------------------------------

  test "a tool call is made on behalf of the run's actor" do
    agent = create_agent
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :running)
    run.actor = agent # any object; the engine never interprets one

    ActionAgent::AgentExecutionService.new(agent, run).execute_tool("find_records", status: "open")

    call = RecordingTools.calls.sole
    assert_equal agent, call[:actor]
    assert_equal({ status: "open" }, call[:arguments])
  end

  test "an unattributed run passes nil rather than something more privileged" do
    agent = create_agent
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :running)

    ActionAgent::AgentExecutionService.new(agent, run).execute_tool("find_records")

    assert_nil RecordingTools.calls.sole[:actor]
  end

  # --- and cannot be forged ----------------------------------------------

  test "a caller named by the model is dropped before the tool sees it" do
    agent = create_agent
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :running)
    run.actor = nil

    # Everything in kwargs came from the model, and everything a model emits
    # is reachable by whatever it just read.
    ActionAgent::AgentExecutionService.new(agent, run)
      .execute_tool("find_records", actor: "administrator", current_user: "administrator", status: "open")

    call = RecordingTools.calls.sole
    assert_nil call[:actor]
    assert_equal({ status: "open" }, call[:arguments])
  end

  test "a caller named in the request's run parameters is refused the same way" do
    agent = create_agent

    run = agent.test_execute("hello", actor: nil, actor_override: "administrator")

    # It reached input_params as an ordinary parameter and nothing else: the
    # controller reserves the real keyword (RESERVED_EXECUTION_KEYS), and the
    # run records its actor under a key of its own.
    assert_nil run.actor
    assert_equal "administrator", run.input_params["actor_override"]
  end

  test "the stored actor key is never taken from the caller's parameters" do
    params = { ActionAgent::AgentRun::ACTOR_PARAM => "gid://app/User/1", "temperature" => 0.2 }

    assert_equal({ "temperature" => 0.2 }, ActionAgent::AgentRun.params_with_actor(params, nil))
  end

  # --- it survives the trip to a worker ----------------------------------

  test "an actor that can be addressed globally is recorded and rehydrated" do
    agent = create_agent
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :pending)
    run.update!(input_params: ActionAgent::AgentRun.params_with_actor({}, agent))

    assert run.actor_recorded?
    assert_equal agent.to_global_id.to_s, run.input_params[ActionAgent::AgentRun::ACTOR_PARAM]
    # Read back the way a worker would: a fresh record, no memory of the call.
    assert_equal agent, ActionAgent::AgentRun.find(run.id).actor
  end

  test "an actor that no longer resolves loses access rather than inheriting it" do
    agent = create_agent(name: "Records")
    caller_record = create_agent(name: "Caller")
    run = agent.agent_runs.create!(
      trace_id: SecureRandom.uuid, status: :pending,
      input_params: ActionAgent::AgentRun.params_with_actor({}, caller_record)
    )
    caller_record.destroy

    stored = ActionAgent::AgentRun.find(run.id)
    assert stored.actor_recorded?, "the run still says it was for someone"
    assert_nil stored.actor, "but it resolves to nobody, not to a fallback"
  end

  test "an actor with no global address is not recorded, and the run stays unattributed" do
    params = ActionAgent::AgentRun.params_with_actor({ "temperature" => 0.2 }, Object.new)

    assert_equal({ "temperature" => 0.2 }, params)
  end

  # --- one caller's rows are never another's -----------------------------

  test "a scoped tool result is not replayed for the next caller" do
    first = create_agent(name: "First")
    second = create_agent(name: "Second")

    ActionAgent::AgentToolbox.call("find_records", actor: first, status: "open")
    ActionAgent::AgentToolbox.call("find_records", actor: second, status: "open")

    # Same tool, same arguments, different caller: the second call runs
    # rather than replaying the first caller's answer from the cache.
    assert_equal [ first, second ], RecordingTools.calls.map { |call| call[:actor] }
  end

  test "a built-in tool never meets the actor as an argument" do
    # calculate takes (expression:) only — passing the caller through as a
    # keyword would make every built-in fail with an argument error.
    result = ActionAgent::AgentToolbox.call("calculate", actor: create_agent, expression: "2 + 3")

    assert_equal 5, result[:result]
  end
end
