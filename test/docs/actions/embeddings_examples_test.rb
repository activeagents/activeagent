require "test_helper"

module Docs
  module Agents
    module EmbeddingsExamples
      class QuickStart < ActiveSupport::TestCase
        test "quick start example" do
          VCR.use_cassette("docs/agents/embeddings_examples/quick_start") do
            # region quick_start
            class MyAgent < ApplicationAgent
              embed_with :openai, model: "text-embedding-3-small"

              def vectorize
                embed(input: params[:text])
              end
            end

            response = MyAgent.with(text: "Hello world").vectorize.embed_now
            vector = response.data.first[:embedding]  # => [0.123, -0.456, ...]
            # endregion quick_start

            assert_kind_of Array, vector
            assert vector.all? { |v| v.is_a?(Float) }
          end
        end
      end

      class BasicUsage < ActiveSupport::TestCase
        test "direct embedding" do
          VCR.use_cassette("docs/agents/embeddings_examples/direct_embedding") do
            # region direct_embedding
            response = ApplicationAgent.embed(
              input: "The quick brown fox",
              model: "text-embedding-3-small"
            ).embed_now
            vector = response.data.first[:embedding]
            # endregion direct_embedding

            assert_kind_of Array, vector
            assert vector.all? { |v| v.is_a?(Float) }
          end
        end

        test "background processing" do
          # region background_processing
          job = ApplicationAgent.embed(
            input: "Long document text",
            model: "text-embedding-3-small"
          ).embed_later(
            queue: :embeddings,
            priority: 10
          )
          # endregion background_processing

          assert_kind_of ActiveAgent::GenerationJob, job
        end

        test "multiple inputs" do
          VCR.use_cassette("docs/agents/embeddings_examples/multiple_inputs") do
            # region multiple_inputs
            response = ApplicationAgent.embed(
              input: [ "First text", "Second text", "Third text" ],
              model: "text-embedding-3-small"
            ).embed_now

            vectors = response.data.pluck(:embedding)
            # endregion multiple_inputs

            assert_equal 3, vectors.size
            assert vectors.all? { |v| v.is_a?(Array) }
          end
        end
      end

      class ResponseStructure < ActiveSupport::TestCase
        test "accessing embedding vector" do
          VCR.use_cassette("docs/agents/embeddings_examples/response_structure") do
            # region response_structure
            response = ApplicationAgent.embed(
              input: "Sample text",
              model: "text-embedding-3-small"
            ).embed_now

            # Access embedding vector
            vector = response.data.first[:embedding]  # Array of floats

            # Check dimensions
            vector.size  # => 1536 (varies by model)
            # endregion response_structure

            assert_kind_of Array, vector
            assert vector.all? { |v| v.is_a?(Float) }
          end
        end
      end

      class Configuration < ActiveSupport::TestCase
        test "basic configuration" do
          VCR.use_cassette("docs/agents/embeddings_examples/basic_configuration") do
            # region basic_configuration
            class EmbeddingAgent < ApplicationAgent
              embed_with :openai, model: "text-embedding-3-small"
            end

            response = EmbeddingAgent.embed(input: "Your text").embed_now
            # endregion basic_configuration

            assert_not_nil response
          end
        end

        test "mixing providers" do
          VCR.use_cassette("docs/agents/embeddings_examples/mixing_providers") do
            # region mixing_providers
            class HybridAgent < ApplicationAgent
              generate_with :anthropic, model: "claude-3-5-sonnet-20241022"
              embed_with :openai, model: "text-embedding-3-small"
            end

            # Use Anthropic for chat
            chat_response = HybridAgent.prompt(message: "Hello").generate_now

            # Use OpenAI for embeddings
            embed_response = HybridAgent.embed(input: "Hello").embed_now
            # endregion mixing_providers

            assert_not_nil chat_response
            assert_not_nil embed_response
          end
        end

        test "openai specific options" do
          # region openai_options
          class OpenAIAgent < ApplicationAgent
            embed_with :openai,
              model: "text-embedding-3-small",
              dimensions: 512  # Reduce from default 1536
          end
          # endregion openai_options

          assert_not_nil OpenAIAgent
        end

        test "ollama configuration" do
          # region ollama_configuration
          class OllamaAgent < ApplicationAgent
            embed_with :ollama,
              model: "nomic-embed-text",
              host: "http://localhost:11434"
          end
          # endregion ollama_configuration

          assert_not_nil OllamaAgent
        end
      end

      class Callbacks < ActiveSupport::TestCase
        class Rails
          class Logger
            def self.info(...); end
          end

          def self.logger
            Logger
          end
        end

        test "embedding callbacks" do
          VCR.use_cassette("docs/agents/embeddings_examples/callbacks") do
            # region embedding_callbacks
            class TrackedAgent < ApplicationAgent
              embed_with :openai, model: "text-embedding-3-small"

              before_embed :log_start
              after_embed :log_complete

              private

              def log_start
                Rails.logger.info "Starting embedding generation"
              end

              def log_complete
                Rails.logger.info "Embedding complete"
              end
            end

            response = TrackedAgent.embed(input: "Text").embed_now
            # Logs before and after generation
            # endregion embedding_callbacks

            assert_not_nil response
          end
        end
      end

      class SimilaritySearch < ActiveSupport::TestCase
        test "cosine similarity search" do
          VCR.use_cassette("docs/agents/embeddings_examples/cosine_similarity") do
            # region cosine_similarity
            def cosine_similarity(vec1, vec2)
              dot_product = vec1.zip(vec2).map { |a, b| a * b }.sum
              magnitude1 = Math.sqrt(vec1.map { |v| v**2 }.sum)
              magnitude2 = Math.sqrt(vec2.map { |v| v**2 }.sum)
              dot_product / (magnitude1 * magnitude2)
            end

            documents = [
              "The cat sat on the mat",
              "Dogs are loyal companions",
              "Machine learning is a subset of AI",
              "The feline rested on the rug"
            ]

            # Generate embeddings
            response   = ApplicationAgent.embed(
              input: documents,
              model: "text-embedding-3-small"
            ).embed_now
            embeddings = response.data.map { |item| item[:embedding] }

            # Query
            query = "cat on mat"
            query_embedding = ApplicationAgent.embed(
              input: query,
              model: "text-embedding-3-small"
            ).embed_now.data.first[:embedding]

            # Calculate similarities
            results = embeddings.map.with_index do |embedding, i|
              similarity = cosine_similarity(query_embedding, embedding)
              { document: documents[i], similarity: }
            end.sort_by { |r| -r[:similarity] }

            results.first[:document]  # => "The cat sat on the mat"
            # endregion cosine_similarity

            assert_equal "The cat sat on the mat", results.first[:document]
            assert results.first[:similarity] > 0.5
          end
        end
      end

      class ModelDimensions < ActiveSupport::TestCase
        test "checking dimensions" do
          VCR.use_cassette("docs/agents/embeddings_examples/model_dimensions") do
            # region model_dimensions
            # OpenAI text-embedding-3-small: 1536 dimensions (default)
            # OpenAI text-embedding-3-large: 3072 dimensions
            # OpenAI text-embedding-ada-002: 1536 dimensions
            # Ollama nomic-embed-text: 768 dimensions

            response = ApplicationAgent.embed(
              input: "Test",
              model: "text-embedding-3-small"
            ).embed_now
            dimensions = response.data.first[:embedding].size
            # endregion model_dimensions

            assert dimensions > 0
          end
        end

        test "reducing dimensions" do
          # region reducing_dimensions
          class CompactAgent < ApplicationAgent
            embed_with :openai,
              model: "text-embedding-3-small",
              dimensions: 512  # Smaller, faster
          end
          # endregion reducing_dimensions

          assert_not_nil CompactAgent
        end
      end

      class ErrorHandling < ActiveSupport::TestCase
        class Rails
          class Logger
            def self.error(...); end
          end

          def self.logger
            Logger
          end
        end

        test "handling provider errors" do
          skip "Error handling example - would fail in test"

          # region error_handling
          begin
            response = OllamaAgent.embed(input: "Text").embed_now
            _vector = response.data.first[:embedding]
          rescue Errno::ECONNREFUSED => e
            Rails.logger.error "Ollama not running: #{e.message}"
            # Fallback or retry logic
          end
          # endregion error_handling
        end
      end
    end
  end
end
