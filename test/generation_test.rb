require "test_helper"

class GenerationTest < ActiveSupport::TestCase
  setup do
    # Following the pattern from CLAUDE.md - with returns a Parameterized::Agent,
    # calling an action on it returns a Generation object
    @generation = ApplicationAgent.with(message: "Test embedding content").prompt_context
  end

  test "embed_now calls agent embed method" do
    VCR.use_cassette("generation_embed_now") do
      # Create a generation using the with pattern
      generation = ApplicationAgent.with(message: "Test content for embedding").prompt_context

      # region generation_embed_now
      response = generation.embed_now
      # endregion generation_embed_now

      assert_not_nil response
      assert_instance_of ActiveAgent::GenerationProvider::Response, response

      # Document the output for documentation purposes
      doc_example_output(response)
    end
  end

  test "embed_later queues embedding generation" do
    # Create a generation using the with pattern
    generation = ApplicationAgent.with(message: "Test embedding").prompt_context

    # Test that embed_later calls enqueue_generation with correct parameters
    # Using instance_eval to stub private method
    generation.instance_eval do
      def enqueue_generation(method, options = {})
        @enqueue_called = true
        @enqueue_method = method
        @enqueue_options = options
        true
      end

      def enqueue_called?
        @enqueue_called
      end

      def enqueue_method
        @enqueue_method
      end

      def enqueue_options
        @enqueue_options
      end
    end

    result = generation.embed_later(priority: :high)
    assert result
    assert generation.enqueue_called?
    assert_equal :embed_now, generation.enqueue_method
    assert_equal({ priority: :high }, generation.enqueue_options)
  end

  test "embed_now processes agent with embedding callbacks" do
    VCR.use_cassette("generation_embed_now_with_callbacks") do
      # Create a custom agent class with embedding callbacks
      custom_agent_class = Class.new(ApplicationAgent) do
        attr_accessor :before_callback_executed, :after_callback_executed

        before_embedding :set_before_flag
        after_embedding :set_after_flag

        def set_before_flag
          self.before_callback_executed = true
        end

        def set_after_flag
          self.after_callback_executed = true
        end
      end

      # Create a generation using the custom agent
      generation = custom_agent_class.with(message: "Test embedding with callbacks").prompt_context

      # Get the processed agent to check callbacks
      agent = generation.send(:processed_agent)
      response = generation.embed_now

      assert_not_nil response
      assert agent.before_callback_executed, "Before embedding callback should have been executed"
      assert agent.after_callback_executed, "After embedding callback should have been executed"
    end
  end

  test "embed_later with options passes options to enqueue" do
    # Test various option combinations
    options_to_test = [
      { priority: :high },
      { queue: :embeddings },
      { wait: 5.minutes },
      { priority: :low, queue: :background }
    ]

    options_to_test.each do |options|
      generation = ApplicationAgent.with(message: "Test embedding").prompt_context

      # Using instance_eval to stub private method
      generation.instance_eval do
        def enqueue_generation(method, opts = {})
          @enqueue_method = method
          @enqueue_options = opts
          true
        end

        def enqueue_method
          @enqueue_method
        end

        def enqueue_options
          @enqueue_options
        end
      end

      result = generation.embed_later(options)
      assert result
      assert_equal :embed_now, generation.enqueue_method
      assert_equal options, generation.enqueue_options
    end
  end

  test "generation object supports both generate_now and embed_now" do
    VCR.use_cassette("generation_dual_support") do
      # Create a generation object
      generation = ApplicationAgent.with(message: "Test dual support").prompt_context

      # Test that both methods are available
      assert generation.respond_to?(:generate_now)
      assert generation.respond_to?(:embed_now)
      assert generation.respond_to?(:generate_later)
      assert generation.respond_to?(:embed_later)

      # Test that embed_now works
      embed_response = generation.embed_now
      assert_not_nil embed_response
      assert_instance_of ActiveAgent::GenerationProvider::Response, embed_response

      # Create a new generation for generate_now since we already used the first one
      generation2 = ApplicationAgent.with(message: "Test generate").prompt_context
      generate_response = generation2.generate_now
      assert_not_nil generate_response
      assert_instance_of ActiveAgent::GenerationProvider::Response, generate_response
    end
  end
end
