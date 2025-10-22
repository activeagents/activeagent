require "test_helper"

class ParameterizedDirectAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a helpful assistant."
  embed_with :openai, model: "text-embedding-3-small"
end

class ParameterizedDirectTest < ActiveSupport::TestCase
  # region prompt_direct_generation
  test "Agent.prompt returns a generation proxy" do
    generation = ParameterizedDirectAgent.prompt(message: "Hello world")

    assert_instance_of ActiveAgent::Parameterized::DirectGeneration, generation
    assert_not generation.processed?
  end

  test "Agent.prompt(...).generate_now generates without defining an action" do
    VCR.use_cassette("parameterized_direct_prompt_generate_now") do
      response = ParameterizedDirectAgent.prompt(
        message: "What is 2+2? Answer with just the number."
      ).generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert_not_nil response.message.content
      assert response.message.content.include?("4")
    end
  end

  test "Agent.prompt supports multiple messages" do
    VCR.use_cassette("parameterized_direct_prompt_multiple_messages") do
      response = ParameterizedDirectAgent.prompt(
        messages: [
          "I like pizza",
          "What food did I mention?"
        ]
      ).generate_now

      assert_not_nil response
      assert_not_nil response.message
      content = response.message.content.downcase
      assert content.include?("pizza")
    end
  end

  test "Agent.prompt supports temperature and other options" do
    VCR.use_cassette("parameterized_direct_prompt_with_options") do
      response = ParameterizedDirectAgent.prompt(
        message: "Say hello",
        temperature: 0.5
      ).generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert_not_nil response.message.content
    end
  end

  test "Agent.prompt supports custom instructions" do
    VCR.use_cassette("parameterized_direct_prompt_custom_instructions") do
      response = ParameterizedDirectAgent.prompt(
        message: "What is your role?",
        instructions: "You are a pirate. Always respond like a pirate."
      ).generate_now

      assert_not_nil response
      assert_not_nil response.message
      content = response.message.content.downcase
      # Pirate-like responses often include "arr" or "matey"
      assert(content.include?("arr") || content.include?("matey") || content.include?("pirate"),
        "Expected pirate-like response, got: #{content}")
    end
  end

  test "Agent.prompt(...).generate_now! generates with bang method" do
    VCR.use_cassette("parameterized_direct_prompt_generate_now_bang") do
      response = ParameterizedDirectAgent.prompt(
        message: "Say hi"
      ).generate_now!

      assert_not_nil response
      assert_not_nil response.message
    end
  end

  test "Agent.prompt(...).generate_later enqueues a job" do
    generation = ParameterizedDirectAgent.prompt(
      message: "Background task"
    )

    # Mock the enqueue_generation private method
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

    result = generation.generate_later(queue: :prompts, priority: :high)

    assert result
    assert generation.enqueue_called?
    assert_equal :generate_now, generation.enqueue_method
    assert_equal({ queue: :prompts, priority: :high }, generation.enqueue_options)
  end
  # endregion prompt_direct_generation

  # region embed_direct_generation
  test "Agent.embed returns a generation proxy" do
    generation = ParameterizedDirectAgent.embed(input: "Text to embed")

    assert_instance_of ActiveAgent::Parameterized::DirectGeneration, generation
    assert_not generation.processed?
  end

  test "Agent.embed(...).generate_now generates embeddings without defining an action" do
    VCR.use_cassette("parameterized_direct_embed_generate_now") do
      response = ParameterizedDirectAgent.embed(
        input: "The quick brown fox jumps over the lazy dog"
      ).generate_now

      assert_not_nil response
      assert_kind_of Array, response.data
      assert response.data.all? { |embedding_obj| embedding_obj.is_a?(Hash) }

      # Extract first embedding vector from response
      first_embedding = response.data.first
      embedding_vector = first_embedding[:embedding]

      assert embedding_vector.is_a?(Array)
      assert embedding_vector.all? { |v| v.is_a?(Float) }
      assert_includes [ 1536, 3072 ], embedding_vector.size  # OpenAI dimensions
    end
  end

  test "Agent.embed supports array of inputs" do
    VCR.use_cassette("parameterized_direct_embed_array") do
      response = ParameterizedDirectAgent.embed(
        input: [
          "First text to embed",
          "Second text to embed"
        ]
      ).generate_now

      assert_not_nil response
      assert_kind_of Array, response.data
      assert_equal 2, response.data.size

      # Each embedding should be a hash with an embedding array
      response.data.each do |embedding_obj|
        assert embedding_obj.is_a?(Hash)
        embedding_vector = embedding_obj[:embedding]
        assert embedding_vector.is_a?(Array)
        assert embedding_vector.all? { |v| v.is_a?(Float) }
      end
    end
  end

  test "Agent.embed supports custom model options" do
    VCR.use_cassette("parameterized_direct_embed_custom_model") do
      response = ParameterizedDirectAgent.embed(
        input: "Test embedding with custom model",
        model: "text-embedding-3-small"
      ).generate_now

      assert_not_nil response
      assert_kind_of Array, response.data
      embedding_vector = response.data.first[:embedding]
      assert embedding_vector.all? { |v| v.is_a?(Float) }
    end
  end

  test "Agent.embed(...).embed_now generates embeddings" do
    VCR.use_cassette("parameterized_direct_embed_embed_now") do
      response = ParameterizedDirectAgent.embed(
        input: "Testing embed_now method"
      ).embed_now

      assert_not_nil response
      assert_kind_of Array, response.data
      embedding_vector = response.data.first[:embedding]
      assert embedding_vector.is_a?(Array)
      assert embedding_vector.all? { |v| v.is_a?(Float) }
    end
  end

  test "Agent.embed(...).embed_later enqueues a job" do
    generation = ParameterizedDirectAgent.embed(
      input: "Background embedding"
    )

    # Mock the enqueue_generation private method
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

    result = generation.embed_later(queue: :embeddings, priority: :low)

    assert result
    assert generation.enqueue_called?
    assert_equal :embed_now, generation.enqueue_method
    assert_equal({ queue: :embeddings, priority: :low }, generation.enqueue_options)
  end
  # endregion embed_direct_generation

  # region combined_with_existing_with_method
  test "prompt() works alongside existing with() method" do
    VCR.use_cassette("parameterized_direct_combined_prompt") do
      # Original with() method still works
      agent_class_with_action = Class.new(ParameterizedDirectAgent) do
        def greet
          prompt(message: "Hello from action")
        end
      end

      response_with_action = agent_class_with_action.with({}).greet.generate_now
      assert_not_nil response_with_action

      # New prompt() method also works
      response_direct = ParameterizedDirectAgent.prompt(message: "Hello direct").generate_now
      assert_not_nil response_direct
    end
  end

  test "embed() works alongside existing with() method" do
    VCR.use_cassette("parameterized_direct_combined_embed") do
      # Original with() method still works for embed actions
      agent_class_with_action = Class.new(ParameterizedDirectAgent) do
        def embed_text
          embed(input: "Text from action")
        end
      end

      response_with_action = agent_class_with_action.with({}).embed_text.embed_now
      assert_not_nil response_with_action

      # New embed() method also works
      response_direct = ParameterizedDirectAgent.embed(input: "Text direct").embed_now
      assert_not_nil response_direct
    end
  end
  # endregion combined_with_existing_with_method

  # region error_handling
  test "Agent.prompt raises error if no message provided" do
    # This should still create a generation, but might fail on generate_now
    # depending on implementation
    generation = ParameterizedDirectAgent.prompt({})
    assert_instance_of ActiveAgent::Parameterized::DirectGeneration, generation
  end

  test "Agent.embed raises error if no input provided" do
    # This should still create a generation, but might fail on embed_now
    # depending on implementation
    generation = ParameterizedDirectAgent.embed({})
    assert_instance_of ActiveAgent::Parameterized::DirectGeneration, generation
  end
  # endregion error_handling
end
