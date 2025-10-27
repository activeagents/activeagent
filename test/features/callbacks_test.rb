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

  test "defines prompting and embedding callbacks" do
    assert_respond_to TestAgent, :before_prompt
    assert_respond_to TestAgent, :after_prompt
    assert_respond_to TestAgent, :around_prompt
    assert_respond_to TestAgent, :before_embed
    assert_respond_to TestAgent, :after_embed
    assert_respond_to TestAgent, :around_embed
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

  test "generation backwards compatability" do
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

    agent = agent_class.new
    agent.run_callbacks(:prompting) do
      agent.callback_order << :prompting_executed
    end

    assert_equal [ :before_generation, :before_around, :prompting_executed, :after_around, :after_generation ], agent.callback_order
  end
end
