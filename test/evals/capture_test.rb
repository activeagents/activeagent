# frozen_string_literal: true

require "test_helper"
require_relative "support/eval_agents"

class EvalsCaptureTest < ActiveSupport::TestCase
  Capture = ActiveAgent::Evals::Capture
  Replay = ActiveAgent::Evals::Replay

  test "a generation becomes a replay with the answer, tokens, timing and the prompt" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask)

    assert_kind_of Replay, replay
    assert_equal "Order ABC-123 is shipped.", replay.answer
    assert_equal 12, replay.input_tokens
    assert_equal 7, replay.output_tokens
    assert_kind_of Integer, replay.duration_ms
    refute replay.errored?
    assert_equal "EvalsTest::OrdersAgent", replay.metadata["agent"]
    assert_equal "ask", replay.metadata["action"]
    assert_equal "Where is order ABC-123?", replay.metadata["prompt"]
    assert_equal "mock-orders", replay.metadata["model"]
  end

  test "every tool call is recorded with its arguments, result and timing" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask)

    assert_equal [ "lookup_order" ], replay.tool_names
    call = replay.tool_calls.first
    assert_equal({ "number" => "ABC-123" }, call["arguments"])
    assert_includes call["detail"], "shipped"
    assert_kind_of Integer, call["duration_ms"]
    refute call["error"]
    assert_empty replay.failed_tool_calls
  end

  test "a tool that raises is recorded as an error and the replay is errored" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order BAD-1?").ask)

    assert replay.errored?
    assert_match(/no such order BAD-1/, replay.error)
    assert_nil replay.answer
    call = replay.tool_calls.first
    assert_equal "lookup_order", call["name"]
    assert call["error"]
    assert_match(/ArgumentError: no such order/, call["detail"])
    assert_equal [ call ], replay.failed_tool_calls
  end

  test "raise_errors re-raises instead of returning an errored replay" do
    error = assert_raises(ArgumentError) do
      Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order BAD-1?").ask, raise_errors: true)
    end

    assert_match(/no such order/, error.message)
  end

  test "an action template renders the prompt as in any run" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(number: "XYZ-9").help)

    assert_equal "Where is order XYZ-9?", replay.metadata["prompt"]
    assert_equal "Order XYZ-9 is shipped.", replay.answer
    assert_equal [ "lookup_order" ], replay.tool_names
  end

  test "a model override runs the agent under that model and leaves the class alone" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask, model: "mock-other")

    assert_equal "mock-other", replay.metadata["model"]
    assert_equal "Order ABC-123 is shipped.", replay.answer
    assert_equal "mock-orders", EvalsTest::OrdersAgent.prompt_options[:model]
  end

  test "a provider override runs a subclass named as the agent, so its templates still resolve" do
    replay = Capture.run(EvalsTest::OrdersAgent.with(number: "XYZ-9").help, provider: :mock, model: "mock-2")

    assert_equal "EvalsTest::OrdersAgent", replay.metadata["agent"]
    assert_equal "mock", replay.metadata["provider"]
    assert_equal "mock-2", replay.metadata["model"]
    # The plain mock provider answers in pig latin; what proves the template
    # rendered under the subclass is the prompt it recorded.
    assert_equal "Where is order XYZ-9?", replay.metadata["prompt"]
    assert replay.answer.present?
    assert_equal ActiveAgent::Providers::MockProvider, EvalsTest::OrdersAgent.prompt_provider_klass.superclass
  end

  test "retarget keeps the generation's params and action and carries the parent's instructions option" do
    parent = Class.new(ActiveAgent::Base) do
      def self.name = "EvalsTest::InstructedAgent"
      generate_with :mock, instructions: "Be brief."
      def ask = prompt(message: params[:question])
    end
    generation = parent.with(question: "hi").ask

    retargeted = Capture.retarget(generation, provider: :mock, model: "mock-3")

    assert_equal "EvalsTest::InstructedAgent", retargeted.agent_class.name
    assert_equal "Be brief.", retargeted.agent_class.prompt_options[:instructions]
    assert_equal "mock-3", retargeted.agent_class.prompt_options[:model]
    assert_equal :ask, retargeted.action_name
    assert_same generation, Capture.retarget(generation)
  end

  test "the block form accepts a response, a replay, a hash or a string" do
    from_response = Capture.run { EvalsTest::OrdersAgent.with(question: "Where is order ABC-123?").ask.generate_now }
    assert_equal "Order ABC-123 is shipped.", from_response.answer
    assert_equal 12, from_response.input_tokens
    assert_empty from_response.tool_calls, "nothing wraps an agent the block runs itself"

    from_replay = Capture.run(metadata: { "run" => 1 }) { Replay.new(answer: "ok", tool_calls: [ { "name" => "t" } ], metadata: { "chat" => 2 }) }
    assert_equal "ok", from_replay.answer
    assert_equal [ "t" ], from_replay.tool_names
    assert_equal({ "run" => 1, "chat" => 2 }, from_replay.metadata)
    assert_kind_of Integer, from_replay.duration_ms

    from_hash = Capture.run { { answer: "hash", output_tokens: 3 } }
    assert_equal "hash", from_hash.answer
    assert_equal 3, from_hash.output_tokens

    from_string = Capture.run { "plain" }
    assert_equal "plain", from_string.answer
  end

  test "a block that raises becomes an errored replay" do
    replay = Capture.run { raise "model down" }

    assert replay.errored?
    assert_equal "RuntimeError: model down", replay.error
  end

  test "a block that returns something else is the caller's bug" do
    assert_raises(ArgumentError) { Capture.run { 42 } }
    assert_raises(ArgumentError) { Capture.run }
  end

  test "tool arguments and results are recorded as JSON would carry them" do
    assert_equal({ "number" => "1", "nested" => { "a" => [ 1, 2 ] } }, Capture.jsonable({ number: "1", nested: { a: [ 1, 2 ] } }))
    assert_equal "short", Capture.preview("short")
    assert_equal Capture::DETAIL_LIMIT + 1, Capture.preview("x" * 1_000).length
    assert_equal '{"status":"shipped"}', Capture.preview({ status: "shipped" })
  end
end
