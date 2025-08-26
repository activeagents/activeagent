require "test_helper"

class EmbeddingAgentTest < ActiveSupport::TestCase
  # region embedding_sync_generation
  test "generates embeddings synchronously with embed_now" do
    VCR.use_cassette("embedding_agent_sync") do
      # Create a generation for embedding
      generation = ApplicationAgent.with(
        message: "The quick brown fox jumps over the lazy dog"
      ).prompt_context

      # Generate embedding synchronously
      response = generation.embed_now

      # Extract embedding vector
      embedding_vector = response.message.content

      assert_kind_of Array, embedding_vector
      assert embedding_vector.all? { |v| v.is_a?(Float) }
      assert_includes [ 1536, 3072 ], embedding_vector.size  # OpenAI dimensions vary by model

      # Document the example
      doc_example_output(response)

      embedding_vector
    end
  end
  # endregion embedding_sync_generation

  # region embedding_async_generation
  test "generates embeddings asynchronously with embed_later" do
    # Create a generation for async embedding
    generation = ApplicationAgent.with(
      message: "Artificial intelligence is transforming technology"
    ).prompt_context

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

    # Queue embedding for background processing
    result = generation.embed_later(
      priority: :low,
      queue: :embeddings
    )

    assert result
    assert generation.enqueue_called?
    assert_equal :embed_now, generation.enqueue_method
    assert_equal({ priority: :low, queue: :embeddings }, generation.enqueue_options)
  end
  # endregion embedding_async_generation

  # region embedding_with_callbacks
  test "processes embeddings with callbacks" do
    VCR.use_cassette("embedding_agent_callbacks") do
      # Create a custom agent with embedding callbacks
      custom_agent_class = Class.new(ApplicationAgent) do
        attr_accessor :before_embedding_called, :after_embedding_called

        before_embedding :track_before
        after_embedding :track_after

        def track_before
          self.before_embedding_called = true
        end

        def track_after
          self.after_embedding_called = true
        end
      end

      # Generate embedding with callbacks
      generation = custom_agent_class.with(
        message: "Testing embedding callbacks"
      ).prompt_context

      agent = generation.send(:processed_agent)
      response = generation.embed_now

      assert agent.before_embedding_called
      assert agent.after_embedding_called
      assert_not_nil response.message.content

      doc_example_output(response)
    end
  end
  # endregion embedding_with_callbacks

  # region embedding_similarity_search
  test "performs similarity search with embeddings" do
    VCR.use_cassette("embedding_similarity_search") do
      documents = [
        "The cat sat on the mat",
        "Dogs are loyal companions",
        "Machine learning is a subset of AI",
        "The feline rested on the rug"
      ]

      # Generate embeddings for all documents
      embeddings = documents.map do |doc|
        generation = ApplicationAgent.with(message: doc).prompt_context
        generation.embed_now.message.content
      end

      # Query embedding
      query = "cat on mat"
      query_generation = ApplicationAgent.with(message: query).prompt_context
      query_embedding = query_generation.embed_now.message.content

      # Calculate cosine similarities
      similarities = embeddings.map.with_index do |embedding, index|
        similarity = cosine_similarity(query_embedding, embedding)
        { document: documents[index], similarity: similarity }
      end

      # Sort by similarity
      results = similarities.sort_by { |s| -s[:similarity] }

      # Most similar should be the cat/mat documents
      assert_equal "The cat sat on the mat", results.first[:document]
      assert results.first[:similarity] > 0.5, "Similarity should be > 0.5, got #{results.first[:similarity]}"

      # Document the results
      doc_example_output(results.first(2))
    end
  end
  # endregion embedding_similarity_search

  # region embedding_dimension_test
  test "verifies embedding dimensions for different models" do
    VCR.use_cassette("embedding_dimensions") do
      # Test with default model (usually text-embedding-3-small or ada-002)
      generation = ApplicationAgent.with(
        message: "Testing embedding dimensions"
      ).prompt_context

      response = generation.embed_now
      embedding = response.message.content

      # Most OpenAI models return 1536 dimensions by default
      assert_includes [ 1536, 3072 ], embedding.size

      doc_example_output({
        model: "default",
        dimensions: embedding.size,
        sample: embedding[0..4]
      })
    end
  end
  # endregion embedding_dimension_test

  # region embedding_openai_model_config
  test "uses configured OpenAI embedding model" do
    VCR.use_cassette("embedding_openai_model") do
      # Create agent with specific OpenAI model configuration
      custom_agent_class = Class.new(ApplicationAgent) do
        generate_with :openai,
          model: "gpt-4o",
          embedding_model: "text-embedding-3-small"
      end

      generation = custom_agent_class.with(
        message: "Testing OpenAI embedding model configuration"
      ).prompt_context

      response = generation.embed_now
      embedding = response.message.content

      # text-embedding-3-small can have different dimensions depending on truncation
      assert_includes [ 1536, 3072 ], embedding.size
      assert embedding.all? { |v| v.is_a?(Float) }

      doc_example_output({
        model: "text-embedding-3-small",
        dimensions: embedding.size,
        sample: embedding[0..2]
      })
    end
  end
  # endregion embedding_openai_model_config

  # region embedding_ollama_provider_test
  test "generates embeddings with Ollama provider" do
    VCR.use_cassette("embedding_ollama_provider") do
      # Create agent configured for Ollama
      ollama_agent_class = Class.new(ApplicationAgent) do
        generate_with :ollama,
          model: "llama3",
          embedding_model: "nomic-embed-text",
          host: "http://localhost:11434"
      end

      generation = ollama_agent_class.with(
        message: "Testing Ollama embedding generation"
      ).prompt_context

      begin
        response = generation.embed_now
        embedding = response.message.content

        assert_kind_of Array, embedding
        assert embedding.all? { |v| v.is_a?(Numeric) }
        assert embedding.size > 0

        doc_example_output({
          provider: "ollama",
          model: "nomic-embed-text",
          dimensions: embedding.size,
          sample: embedding[0..2]
        })
      rescue Errno::ECONNREFUSED, Net::OpenTimeout => e
        # Document the expected error when Ollama is not running
        doc_example_output({
          error: "Connection refused",
          message: "Ollama is not running locally",
          solution: "Start Ollama with: ollama serve"
        })
        skip "Ollama is not running locally: #{e.message}"
      end
    end
  end
  # endregion embedding_ollama_provider_test

  # region embedding_batch_processing
  test "processes multiple embeddings in batch" do
    VCR.use_cassette("embedding_batch_processing") do
      texts = [
        "First document for embedding",
        "Second document with different content",
        "Third document about technology"
      ]

      embeddings = []
      texts.each do |text|
        generation = ApplicationAgent.with(message: text).prompt_context
        embedding = generation.embed_now.message.content
        embeddings << {
          text: text[0..20] + "...",
          dimensions: embedding.size,
          sample: embedding[0..2]
        }
      end

      assert_equal 3, embeddings.size
      embeddings.each do |result|
        assert result[:dimensions] > 0
        assert result[:sample].all? { |v| v.is_a?(Float) }
      end

      doc_example_output(embeddings)
    end
  end
  # endregion embedding_batch_processing

  private

  def cosine_similarity(vec1, vec2)
    dot_product = vec1.zip(vec2).map { |a, b| a * b }.sum
    magnitude1 = Math.sqrt(vec1.map { |v| v**2 }.sum)
    magnitude2 = Math.sqrt(vec2.map { |v| v**2 }.sum)

    return 0.0 if magnitude1 == 0 || magnitude2 == 0

    dot_product / (magnitude1 * magnitude2)
  end
end
