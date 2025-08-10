require "test_helper"

class BroadcastSpy
  attr_reader :calls

  def initialize
    @calls = []
  end

  def broadcast(*args)
    @calls << args
    true
  end
end

class AgentWithCallbacks < ActiveAgent::Base
  layout "agent"

  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a helpful assistant."
end

class CallbacksWithConditions < AgentWithCallbacks
  before_generation :update_context_id, only: :test_action
  after_generation :filter_response_message, except: :test_action
  on_stream :broadcast_message, only: :stream_action

  def test_action
    prompt_context(message: "Show me a cat")
  end

  def another_test_action
    prompt_context(message: "Show me a cat")
  end

  def stream_action
    prompt_context(message: "Stream this message", options: { stream: true })
  end

  private

  def update_context_id
    context.context_id = 2000
  end

  def filter_response_message
    generation_provider.response.message.content = "[FILTERED]"
  end

  def broadcast_message
    response = generation_provider.response

    ActionCable.server.broadcast("broadcast_message", response)
  end
end

class TestCallbacksWithConditions < ActiveSupport::TestCase
  def setup
    @agent_class = CallbacksWithConditions
  end

  test "when :only is specified, a before action is triggered on that action" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.test_action.generate_now
      assert_equal 2000, generation_result.prompt.context_id
    end

    VCR.use_cassette("streaming_agent_stream_response") do
      spy = BroadcastSpy.new

      ActionCable.stub :server, spy do
        @agent_class.stream_action.generate_now
      end

      assert_equal 84, spy.calls.size
    end
  end

  test "when :only is specified, a before action is not triggered on other actions" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.another_test_action.generate_now
      assert_nil generation_result.prompt.context_id
    end
  end

  test "when :except is specified, an after action is not triggered on that action" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.test_action.generate_now
      assert_not_equal "[FILTERED]", generation_result.message.content
    end
  end

  test "when :except is specified, an after action is triggered on other actions" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.another_test_action.generate_now
      assert_equal "[FILTERED]", generation_result.message.content
    end
  end
end

class CallbacksWithChangedConditions < CallbacksWithConditions
  before_generation :update_context_id, only: :another_test_action
end

class TestCallbacksWithChangedConditions < ActiveSupport::TestCase
  def setup
    @agent_class = CallbacksWithChangedConditions
  end

  test "when a callback is modified in a child with :only, it works for the :only action" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.another_test_action.generate_now
      assert_equal 2000, generation_result.prompt.context_id
    end
  end

  test "when a callback is modified in a child with :only, it does not work for other actions" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.test_action.generate_now
      assert_nil generation_result.prompt.context_id
    end
  end
end

class CallbacksWithArrayConditions < AgentWithCallbacks
  before_generation :update_context_id, only: %i[test_action another_test_action]

  def test_action
    prompt_context(message: "Show me a cat")
  end

  def another_test_action
    prompt_context(message: "Show me a cat")
  end

  def yet_another_test_action
    prompt_context(message: "Show me a cat")
  end

  private

  def update_context_id
    context.context_id = 2000
  end
end

class TestCallbacksWithArrayConditions < ActiveSupport::TestCase
  def setup
    @agent_class = CallbacksWithArrayConditions
  end

  test "when :only is specified with an array, a before action is triggered on that action" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.test_action.generate_now
      assert_equal 2000, generation_result.prompt.context_id
    end

    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.another_test_action.generate_now
      assert_equal 2000, generation_result.prompt.context_id
    end
  end

  test "when :only is specified with an array, a before action is not triggered on other actions" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.yet_another_test_action.generate_now
      assert_nil generation_result.prompt.context_id
    end
  end
end

class AgentWithDefaultStreamOptionCallbacks < ApplicationAgent
  generate_with :openai,
                model: "gpt-4.1-nano",
                instructions: "You're a chat agent. Your job is to help users with their questions.",
                stream: true

  on_stream :broadcast_message

  def stream_action
    prompt_context(message: "Stream this message")
  end

  def another_stream_action
    prompt_context(message: "Stream this message")
  end

  private

  def broadcast_message
    response = generation_provider.response

    ActionCable.server.broadcast("broadcast_message", response)
  end
end

class TestAgentWithDefaultStreamOptionCallbacks < ActiveSupport::TestCase
  def setup
    @agent_class = AgentWithDefaultStreamOptionCallbacks
  end

  test "when :filter option is not specified, an on_stream action is triggered on any action" do
    VCR.use_cassette("streaming_agent_stream_response") do
      spy = BroadcastSpy.new

      ActionCable.stub :server, spy do
        @agent_class.stream_action.generate_now
      end

      assert_equal 84, spy.calls.size
    end

    VCR.use_cassette("streaming_agent_stream_response") do
      spy = BroadcastSpy.new

      ActionCable.stub :server, spy do
        @agent_class.another_stream_action.generate_now
      end

      assert_equal 84, spy.calls.size
    end
  end
end

class AgentWithDefaultStreamOptionWithChangedConditionCallbacks < AgentWithDefaultStreamOptionCallbacks
  on_stream :broadcast_message, only: :stream_action
end

class TestAgentWithDefaultStreamOptionWithChangedConditionCallbacks < ActiveSupport::TestCase
  def setup
    @agent_class = AgentWithDefaultStreamOptionWithChangedConditionCallbacks
  end

  test "when a callback is modified in a child with :only, it works for the :only action" do
    VCR.use_cassette("streaming_agent_stream_response") do
      spy = BroadcastSpy.new

      ActionCable.stub :server, spy do
        @agent_class.stream_action.generate_now
      end

      assert_equal 84, spy.calls.size
    end
  end

  test "when a callback is modified in a child with :only, it does not work for other actions" do
    VCR.use_cassette("streaming_agent_stream_response") do
      spy = BroadcastSpy.new

      ActionCable.stub :server, spy do
        @agent_class.another_stream_action.generate_now
      end

      assert_empty spy.calls, "Expected no broadcast calls"
    end
  end
end
