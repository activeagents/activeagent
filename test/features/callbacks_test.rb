# frozen_string_literal: true

require "test_helper"

class CallbacksTest < ActiveSupport::TestCase
  # Test class that includes the Callbacks concern
  class TestAgent < ActiveAgent::Base
    attr_accessor :callback_order

    def initialize
      super
      @callback_order = []
    end

    def test_action
      @callback_order << :action_executed
    end
  end

  test "defines prompting, embedding, and generation callbacks" do
    assert_respond_to TestAgent, :before_prompt
    assert_respond_to TestAgent, :after_prompt
    assert_respond_to TestAgent, :around_prompt
    assert_respond_to TestAgent, :before_embed
    assert_respond_to TestAgent, :after_embed
    assert_respond_to TestAgent, :around_embed
    assert_respond_to TestAgent, :before_generation
    assert_respond_to TestAgent, :after_generation
    assert_respond_to TestAgent, :around_generation
  end

  test "before_prompt callback is executed" do
    agent_class = Class.new(TestAgent) do
      before_prompt :track_before

      def track_before
        @callback_order << :before_prompt
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :before_prompt, :prompting_executed ], agent.callback_order
  end

  test "after_prompt callback is executed" do
    agent_class = Class.new(TestAgent) do
      after_prompt :track_after

      def track_after
        @callback_order << :after_prompt
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :prompting_executed, :after_prompt ], agent.callback_order
  end

  test "around_prompt callback is executed" do
    agent_class = Class.new(TestAgent) do
      around_prompt :track_around

      def track_around
        @callback_order << :before_around
        yield
        @callback_order << :after_around
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :before_around, :prompting_executed, :after_around ], agent.callback_order
  end

  test "multiple prompting callbacks are executed in order" do
    agent_class = Class.new(TestAgent) do
      before_prompt :first_before
      before_prompt :second_before
      after_prompt :first_after
      after_prompt :second_after

      def first_before
        @callback_order << :first_before
      end

      def second_before
        @callback_order << :second_before
      end

      def first_after
        @callback_order << :first_after
      end

      def second_after
        @callback_order << :second_after
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    # Note: after_* callbacks run in reverse order (LIFO)
    assert_equal [
      :first_before,
      :second_before,
      :prompting_executed,
      :second_after,
      :first_after
    ], agent.callback_order
  end

  test "before_embed callback is executed" do
    agent_class = Class.new(TestAgent) do
      before_embed :track_before

      def track_before
        @callback_order << :before_embed
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :before_embed, :embedding_executed ], agent.callback_order
  end

  test "after_embed callback is executed" do
    agent_class = Class.new(TestAgent) do
      after_embed :track_after

      def track_after
        @callback_order << :after_embed
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :embedding_executed, :after_embed ], agent.callback_order
  end

  test "around_embed callback is executed" do
    agent_class = Class.new(TestAgent) do
      around_embed :track_around

      def track_around
        @callback_order << :before_around
        yield
        @callback_order << :after_around
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :before_around, :embedding_executed, :after_around ], agent.callback_order
  end

  test "prompting callbacks with block" do
    agent_class = Class.new(TestAgent) do
      before_prompt do
        @callback_order << :block_before
      end

      after_prompt do
        @callback_order << :block_after
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :block_before, :prompting_executed, :block_after ], agent.callback_order
  end

  test "embedding callbacks with block" do
    agent_class = Class.new(TestAgent) do
      before_embed do
        @callback_order << :block_before
      end

      after_embed do
        @callback_order << :block_after
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :block_before, :embedding_executed, :block_after ], agent.callback_order
  end

  test "prompting callbacks can be conditionally applied with if" do
    agent_class = Class.new(TestAgent) do
      attr_accessor :should_run_callback

      before_prompt :conditional_callback, if: :should_run_callback

      def conditional_callback
        @callback_order << :conditional_before
      end
    end

    # Test when condition is true
    agent = agent_class.new
    agent.should_run_callback = true
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :conditional_before, :prompting_executed ], agent.callback_order

    # Test when condition is false
    agent = agent_class.new
    agent.should_run_callback = false
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :prompting_executed ], agent.callback_order
  end

  test "prompting callbacks can be conditionally applied with unless" do
    agent_class = Class.new(TestAgent) do
      attr_accessor :skip_callback

      before_prompt :conditional_callback, unless: :skip_callback

      def conditional_callback
        @callback_order << :conditional_before
      end
    end

    # Test when condition is false (callback should run)
    agent = agent_class.new
    agent.skip_callback = false
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :conditional_before, :prompting_executed ], agent.callback_order

    # Test when condition is true (callback should not run)
    agent = agent_class.new
    agent.skip_callback = true
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :prompting_executed ], agent.callback_order
  end

  test "callbacks are inherited by subclasses" do
    parent_class = Class.new(TestAgent) do
      before_prompt :parent_callback

      def parent_callback
        @callback_order << :parent_before
      end
    end

    child_class = Class.new(parent_class) do
      before_prompt :child_callback

      def child_callback
        @callback_order << :child_before
      end
    end

    agent = child_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :parent_before, :child_before, :prompting_executed ], agent.callback_order
  end

  test "after callbacks are skipped if terminated" do
    agent_class = Class.new(TestAgent) do
      before_prompt :terminate_callback_chain
      after_prompt :should_not_run

      def terminate_callback_chain
        @callback_order << :before_prompt
        throw :abort
      end

      def should_not_run
        @callback_order << :after_prompt
      end
    end

    agent = agent_class.new
    result = agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    # When callback chain is aborted, the block doesn't execute and after callbacks don't run
    assert_equal [ :before_prompt ], agent.callback_order
    assert_equal false, result
  end

  test "embedding after callbacks are skipped if terminated" do
    agent_class = Class.new(TestAgent) do
      before_embed :terminate_callback_chain
      after_embed :should_not_run

      def terminate_callback_chain
        @callback_order << :before_embed
        throw :abort
      end

      def should_not_run
        @callback_order << :after_embed
      end
    end

    agent = agent_class.new
    result = agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :before_embed ], agent.callback_order
    assert_equal false, result
  end

  test "generation callbacks wrap both prompting and embedding" do
    agent_class = Class.new(TestAgent) do
      before_generation :track_before
      after_generation :track_after
      around_generation :track_around

      def track_before
        @callback_order << :before_generation
      end

      def track_after
        @callback_order << :after_generation
      end

      def track_around
        @callback_order << :before_around
        yield
        @callback_order << :after_around
      end
    end

    # Test with prompting
    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:prompting) do
        agent.callback_order << :prompting_executed
      end
    end

    assert_equal [ :before_generation, :before_around, :prompting_executed, :after_around, :after_generation ], agent.callback_order

    # Test with embedding
    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:embedding) do
        agent.callback_order << :embedding_executed
      end
    end

    assert_equal [ :before_generation, :before_around, :embedding_executed, :after_around, :after_generation ], agent.callback_order
  end

  test "generation callbacks for rate limiting work across prompting and embedding" do
    rate_limiter = { count: 0 }

    agent_class = Class.new(TestAgent) do
      attr_accessor :rate_limiter

      before_generation :check_rate_limit
      after_generation :record_usage

      def check_rate_limit
        @callback_order << :check_rate_limit
        throw :abort if @rate_limiter[:count] >= 3
      end

      def record_usage
        @callback_order << :record_usage
        @rate_limiter[:count] += 1
      end
    end

    # First prompt - should succeed
    agent = agent_class.new
    agent.rate_limiter = rate_limiter
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:prompting) do
        agent.callback_order << :prompting_executed
      end
    end

    assert_equal [ :check_rate_limit, :prompting_executed, :record_usage ], agent.callback_order
    assert_equal 1, rate_limiter[:count]

    # First embed - should succeed
    agent = agent_class.new
    agent.rate_limiter = rate_limiter
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:embedding) do
        agent.callback_order << :embedding_executed
      end
    end

    assert_equal [ :check_rate_limit, :embedding_executed, :record_usage ], agent.callback_order
    assert_equal 2, rate_limiter[:count]

    # Second prompt - should succeed
    agent = agent_class.new
    agent.rate_limiter = rate_limiter
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:prompting) do
        agent.callback_order << :prompting_executed
      end
    end

    assert_equal [ :check_rate_limit, :prompting_executed, :record_usage ], agent.callback_order
    assert_equal 3, rate_limiter[:count]

    # Second embed - should be blocked by rate limit
    agent = agent_class.new
    agent.rate_limiter = rate_limiter
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:embedding) do
        agent.callback_order << :embedding_executed
      end
    end

    assert_equal [ :check_rate_limit ], agent.callback_order
    assert_equal 3, rate_limiter[:count] # Count shouldn't increase
  end

  test "prepend_before_prompt adds callback at the beginning" do
    agent_class = Class.new(TestAgent) do
      before_prompt :second_callback
      prepend_before_prompt :first_callback

      def first_callback
        @callback_order << :first
      end

      def second_callback
        @callback_order << :second
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :first, :second, :prompting_executed ], agent.callback_order
  end

  test "prepend_after_prompt adds callback at the beginning of after callbacks" do
    agent_class = Class.new(TestAgent) do
      after_prompt :second_callback
      prepend_after_prompt :first_callback

      def first_callback
        @callback_order << :first
      end

      def second_callback
        @callback_order << :second
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    # After callbacks run in reverse order, so prepended one runs last
    assert_equal [ :prompting_executed, :second, :first ], agent.callback_order
  end

  test "prepend_around_prompt adds callback at the beginning" do
    agent_class = Class.new(TestAgent) do
      around_prompt :second_callback
      prepend_around_prompt :first_callback

      def first_callback
        @callback_order << :first_before
        yield
        @callback_order << :first_after
      end

      def second_callback
        @callback_order << :second_before
        yield
        @callback_order << :second_after
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :first_before, :second_before, :prompting_executed, :second_after, :first_after ], agent.callback_order
  end

  test "skip_before_prompt removes previously defined callback" do
    parent_class = Class.new(TestAgent) do
      before_prompt :parent_callback

      def parent_callback
        @callback_order << :parent_before
      end
    end

    child_class = Class.new(parent_class) do
      skip_before_prompt :parent_callback
      before_prompt :child_callback

      def child_callback
        @callback_order << :child_before
      end
    end

    agent = child_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :child_before, :prompting_executed ], agent.callback_order
  end

  test "skip_after_prompt removes previously defined callback" do
    parent_class = Class.new(TestAgent) do
      after_prompt :parent_callback

      def parent_callback
        @callback_order << :parent_after
      end
    end

    child_class = Class.new(parent_class) do
      skip_after_prompt :parent_callback
      after_prompt :child_callback

      def child_callback
        @callback_order << :child_after
      end
    end

    agent = child_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :prompting_executed, :child_after ], agent.callback_order
  end

  test "skip_around_prompt removes previously defined callback" do
    parent_class = Class.new(TestAgent) do
      around_prompt :parent_callback

      def parent_callback
        @callback_order << :parent_around_before
        yield
        @callback_order << :parent_around_after
      end
    end

    child_class = Class.new(parent_class) do
      skip_around_prompt :parent_callback
      around_prompt :child_callback

      def child_callback
        @callback_order << :child_around_before
        yield
        @callback_order << :child_around_after
      end
    end

    agent = child_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :child_around_before, :prompting_executed, :child_around_after ], agent.callback_order
  end

  test "append_before_prompt is alias for before_prompt" do
    agent_class = Class.new(TestAgent) do
      append_before_prompt :track_before

      def track_before
        @callback_order << :before_prompt
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :before_prompt, :prompting_executed ], agent.callback_order
  end

  test "prepend_before_embed adds callback at the beginning" do
    agent_class = Class.new(TestAgent) do
      before_embed :second_callback
      prepend_before_embed :first_callback

      def first_callback
        @callback_order << :first
      end

      def second_callback
        @callback_order << :second
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :first, :second, :embedding_executed ], agent.callback_order
  end

  test "skip_before_embed removes previously defined callback" do
    parent_class = Class.new(TestAgent) do
      before_embed :parent_callback

      def parent_callback
        @callback_order << :parent_before
      end
    end

    child_class = Class.new(parent_class) do
      skip_before_embed :parent_callback
      before_embed :child_callback

      def child_callback
        @callback_order << :child_before
      end
    end

    agent = child_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :child_before, :embedding_executed ], agent.callback_order
  end

  test "append_before_embed is alias for before_embed" do
    agent_class = Class.new(TestAgent) do
      append_before_embed :track_before

      def track_before
        @callback_order << :before_embed
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :before_embed, :embedding_executed ], agent.callback_order
  end

  test "prepend_before_generation works" do
    agent_class = Class.new(TestAgent) do
      before_generation :second_callback
      prepend_before_generation :first_callback

      def first_callback
        @callback_order << :first
      end

      def second_callback
        @callback_order << :second
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:prompting) do
        agent.callback_order << :prompting_executed
      end
    end

    assert_equal [ :first, :second, :prompting_executed ], agent.callback_order
  end

  test "skip_before_generation works" do
    parent_class = Class.new(TestAgent) do
      before_generation :parent_callback

      def parent_callback
        @callback_order << :parent_before
      end
    end

    child_class = Class.new(parent_class) do
      skip_before_generation :parent_callback
    end

    agent = child_class.new
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:prompting) do
        agent.callback_order << :prompting_executed
      end
    end

    assert_equal [ :prompting_executed ], agent.callback_order
  end

  test "append_before_generation is alias for before_generation" do
    agent_class = Class.new(TestAgent) do
      append_before_generation :track_before

      def track_before
        @callback_order << :before_generation
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.run_callbacks(:prompting) do
        agent.callback_order << :prompting_executed
      end
    end

    assert_equal [ :before_generation, :prompting_executed ], agent.callback_order
  end
end
