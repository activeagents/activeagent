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

  setup do
    @agent = TestAgent.new
  end

  test "defines generation and embedding callbacks" do
    assert_respond_to TestAgent, :before_generation
    assert_respond_to TestAgent, :after_generation
    assert_respond_to TestAgent, :around_generation
    assert_respond_to TestAgent, :before_embedding
    assert_respond_to TestAgent, :after_embedding
    assert_respond_to TestAgent, :around_embedding
  end

  test "before_generation callback is executed" do
    agent_class = Class.new(TestAgent) do
      before_generation :track_before

      def track_before
        @callback_order << :before_generation
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :before_generation, :generation_executed ], agent.callback_order
  end

  test "after_generation callback is executed" do
    agent_class = Class.new(TestAgent) do
      after_generation :track_after

      def track_after
        @callback_order << :after_generation
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :generation_executed, :after_generation ], agent.callback_order
  end

  test "around_generation callback is executed" do
    agent_class = Class.new(TestAgent) do
      around_generation :track_around

      def track_around
        @callback_order << :before_around
        yield
        @callback_order << :after_around
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :before_around, :generation_executed, :after_around ], agent.callback_order
  end

  test "multiple generation callbacks are executed in order" do
    agent_class = Class.new(TestAgent) do
      before_generation :first_before
      before_generation :second_before
      after_generation :first_after
      after_generation :second_after

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
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    # Note: after_* callbacks run in reverse order (LIFO)
    assert_equal [
      :first_before,
      :second_before,
      :generation_executed,
      :second_after,
      :first_after
    ], agent.callback_order
  end

  test "before_embedding callback is executed" do
    agent_class = Class.new(TestAgent) do
      before_embedding :track_before

      def track_before
        @callback_order << :before_embedding
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :before_embedding, :embedding_executed ], agent.callback_order
  end

  test "after_embedding callback is executed" do
    agent_class = Class.new(TestAgent) do
      after_embedding :track_after

      def track_after
        @callback_order << :after_embedding
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :embedding_executed, :after_embedding ], agent.callback_order
  end

  test "around_embedding callback is executed" do
    agent_class = Class.new(TestAgent) do
      around_embedding :track_around

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

  test "generation callbacks with block" do
    agent_class = Class.new(TestAgent) do
      before_generation do
        @callback_order << :block_before
      end

      after_generation do
        @callback_order << :block_after
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :block_before, :generation_executed, :block_after ], agent.callback_order
  end

  test "embedding callbacks with block" do
    agent_class = Class.new(TestAgent) do
      before_embedding do
        @callback_order << :block_before
      end

      after_embedding do
        @callback_order << :block_after
      end
    end

    agent = agent_class.new
    agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :block_before, :embedding_executed, :block_after ], agent.callback_order
  end

  test "generation callbacks can be conditionally applied with if" do
    agent_class = Class.new(TestAgent) do
      attr_accessor :should_run_callback

      before_generation :conditional_callback, if: :should_run_callback

      def conditional_callback
        @callback_order << :conditional_before
      end
    end

    # Test when condition is true
    agent = agent_class.new
    agent.should_run_callback = true
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :conditional_before, :generation_executed ], agent.callback_order

    # Test when condition is false
    agent = agent_class.new
    agent.should_run_callback = false
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :generation_executed ], agent.callback_order
  end

  test "generation callbacks can be conditionally applied with unless" do
    agent_class = Class.new(TestAgent) do
      attr_accessor :skip_callback

      before_generation :conditional_callback, unless: :skip_callback

      def conditional_callback
        @callback_order << :conditional_before
      end
    end

    # Test when condition is false (callback should run)
    agent = agent_class.new
    agent.skip_callback = false
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :conditional_before, :generation_executed ], agent.callback_order

    # Test when condition is true (callback should not run)
    agent = agent_class.new
    agent.skip_callback = true
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :generation_executed ], agent.callback_order
  end

  test "callbacks are inherited by subclasses" do
    parent_class = Class.new(TestAgent) do
      before_generation :parent_callback

      def parent_callback
        @callback_order << :parent_before
      end
    end

    child_class = Class.new(parent_class) do
      before_generation :child_callback

      def child_callback
        @callback_order << :child_before
      end
    end

    agent = child_class.new
    agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    assert_equal [ :parent_before, :child_before, :generation_executed ], agent.callback_order
  end

  test "after callbacks are skipped if terminated" do
    agent_class = Class.new(TestAgent) do
      before_generation :terminate_callback_chain
      after_generation :should_not_run

      def terminate_callback_chain
        @callback_order << :before_generation
        throw :abort
      end

      def should_not_run
        @callback_order << :after_generation
      end
    end

    agent = agent_class.new
    result = agent.run_callbacks(:generation) do
      agent.callback_order << :generation_executed
    end

    # When callback chain is aborted, the block doesn't execute and after callbacks don't run
    assert_equal [ :before_generation ], agent.callback_order
    assert_equal false, result
  end

  test "embedding after callbacks are skipped if terminated" do
    agent_class = Class.new(TestAgent) do
      before_embedding :terminate_callback_chain
      after_embedding :should_not_run

      def terminate_callback_chain
        @callback_order << :before_embedding
        throw :abort
      end

      def should_not_run
        @callback_order << :after_embedding
      end
    end

    agent = agent_class.new
    result = agent.run_callbacks(:embedding) do
      agent.callback_order << :embedding_executed
    end

    assert_equal [ :before_embedding ], agent.callback_order
    assert_equal false, result
  end
end
