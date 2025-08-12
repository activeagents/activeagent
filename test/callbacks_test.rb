require "test_helper"

# Mock LLM::Request for testing
module LLM
  class Request
    class << self
      def find_or_create_by_request!(request_params, resource:, task_name:, &block)
        @cache ||= {}
        @call_counts ||= {}

        # Create a cache key based on the request parameters
        cache_key = "#{resource.class.name}_#{task_name}_#{request_params.hash}"
        @call_counts[cache_key] ||= 0
        @call_counts[cache_key] += 1

        # Return cached response if it exists
        if @cache[cache_key]
          return @cache[cache_key]
        end

        # Execute block and store response
        response = yield
        @cache[cache_key] = response
        response
      end

      def reset!
        @cache = {}
        @call_counts = {}
      end
    end
  end
end

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

      assert_equal 54, spy.calls.size
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

      assert_equal 54, spy.calls.size
    end

    VCR.use_cassette("streaming_agent_stream_response") do
      spy = BroadcastSpy.new

      ActionCable.stub :server, spy do
        @agent_class.another_stream_action.generate_now
      end

      assert_equal 54, spy.calls.size
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

      assert_equal 54, spy.calls.size
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

# region around_generation_basic
class AgentWithAroundGeneration < ActiveAgent::Base
  layout "agent"

  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a helpful assistant."

  around_generation :track_generation_calls

  def test_action
    prompt_context(message: "Generate a test response")
  end

  def another_action
    prompt_context(message: "Generate another response")
  end

  private

  def track_generation_calls
    # Track how many times generation is called
    self.class.instance_variable_set(:@generation_count, (self.class.instance_variable_get(:@generation_count) || 0) + 1)

    # Store agent instance in context for tracking
    context.agent_instance.instance_variable_set(:@called_at, Time.current)

    # Execute the actual generation
    yield
  end
end
# endregion around_generation_basic

class TestAgentWithAroundGeneration < ActiveSupport::TestCase
  def setup
    @agent_class = AgentWithAroundGeneration
    @agent_class.instance_variable_set(:@generation_count, 0)
  end

  # region around_generation_test
  test "around_generation wraps the generation process" do
    VCR.use_cassette("openai_prompt_context_response") do
      # First call - should execute the generation
      generation_result = @agent_class.test_action.generate_now

      assert generation_result.message.content.present?
      assert_equal 1, @agent_class.instance_variable_get(:@generation_count)

      # Check that the agent instance was tracked
      assert generation_result.prompt.agent_instance.instance_variable_get(:@called_at).present?
    end
  end
  # endregion around_generation_test

  test "around_generation is called for each generation" do
    VCR.use_cassette("openai_prompt_context_response", allow_playback_repeats: true) do
      # First action
      generation_result1 = @agent_class.test_action.generate_now
      assert generation_result1.message.content.present?
      assert_equal 1, @agent_class.instance_variable_get(:@generation_count)

      # Second action
      generation_result2 = @agent_class.another_action.generate_now
      assert generation_result2.message.content.present?
      assert_equal 2, @agent_class.instance_variable_get(:@generation_count)
    end
  end
end

# region around_generation_conditions
class AgentWithAroundGenerationAndConditions < ActiveAgent::Base
  layout "agent"

  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a helpful assistant."

  around_generation :log_timing, only: :timed_action
  around_generation :cache_llm_request, except: :uncached_action

  def timed_action
    prompt_context(message: "Timed response")
  end

  def cached_action
    prompt_context(message: "Cached response")
  end

  def uncached_action
    prompt_context(message: "Uncached response")
  end

  private

  def log_timing
    start_time = Time.current
    result = yield
    @generation_time = Time.current - start_time
    # Store timing in context for test access through agent_instance
    context.agent_instance.instance_variable_set(:@generation_time, @generation_time)
    result
  end

  def cache_llm_request
    # Simple tracking for the test
    @cached_actions ||= []
    @cached_actions << action_name

    # Store in context for test access
    context.agent_instance.instance_variable_set(:@cached_actions, @cached_actions)

    yield
  end
end
# endregion around_generation_conditions

class TestAgentWithAroundGenerationAndConditions < ActiveSupport::TestCase
  def setup
    @agent_class = AgentWithAroundGenerationAndConditions
    LLM::Request.reset!
  end

  test "around_generation with :only condition applies to specified action" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.timed_action.generate_now

      assert generation_result.message.content.present?
      # Access the timing through the agent instance stored in the context
      agent_instance = generation_result.prompt.agent_instance
      assert agent_instance.instance_variable_get(:@generation_time).present?
      assert agent_instance.instance_variable_get(:@generation_time) > 0
    end
  end

  test "around_generation with :only condition does not apply to other actions" do
    VCR.use_cassette("openai_prompt_context_response") do
      generation_result = @agent_class.cached_action.generate_now

      assert generation_result.message.content.present?
      # The timing callback should not have been called for this action
      agent_instance = generation_result.prompt.agent_instance
      assert_nil agent_instance.instance_variable_get(:@generation_time)
    end
  end

  test "around_generation with :except condition does not apply to excluded action" do
    VCR.use_cassette("openai_prompt_context_response", allow_playback_repeats: true) do
      # Call cached action - should use cache_llm_request
      generation_result1 = @agent_class.cached_action.generate_now
      assert generation_result1.message.content.present?
      cached_actions = generation_result1.prompt.agent_instance.instance_variable_get(:@cached_actions)
      assert_includes cached_actions, "cached_action"

      # Call uncached action - should NOT use cache_llm_request
      generation_result2 = @agent_class.uncached_action.generate_now
      assert generation_result2.message.content.present?
      # This action should not have the cached_actions instance variable
      uncached_agent_actions = generation_result2.prompt.agent_instance.instance_variable_get(:@cached_actions)
      assert_nil uncached_agent_actions
    end
  end
end
