# frozen_string_literal: true

module SolidAgent
  # Searchable provides vector search capabilities using Neighbor gem
  # for semantic search across prompts, messages, and contexts
  #
  # Example:
  #   class Chat < ApplicationRecord
  #     include SolidAgent::Contextual
  #     include SolidAgent::Retrievable  
  #     include SolidAgent::Searchable
  #     
  #     searchable do
  #       embed :messages, model: "text-embedding-3-small"
  #       embed :summary, model: "text-embedding-3-large"
  #       
  #       index :semantic do
  #         field :content
  #         field :metadata
  #       end
  #     end
  #   end
  #
  #   # Find similar contexts
  #   similar_chats = Chat.nearest_neighbors(:embedding, query_embedding, distance: "cosine")
  #   
  #   # Semantic search
  #   results = Chat.semantic_search("How do I reset my password?")
  #
  module Searchable
    extend ActiveSupport::Concern

    included do
      class_attribute :searchable_configuration, default: {}
      class_attribute :embedding_model, default: "text-embedding-3-small"
      class_attribute :embedding_dimensions, default: 1536
      
      # Add neighbor vector search
      has_neighbors :embedding if table_exists? && column_names.include?("embedding")
      
      # Track embeddings for messages
      has_many :message_embeddings,
               class_name: "SolidAgent::Models::MessageEmbedding",
               as: :embeddable,
               dependent: :destroy
               
      # Callbacks for embedding generation
      after_save :generate_embeddings, if: :should_generate_embeddings?
      after_save :update_search_index, if: :should_update_search?
    end

    class_methods do
      # DSL for configuring searchable behavior
      def searchable(&block)
        config = SearchableConfiguration.new
        config.instance_eval(&block) if block_given?
        self.searchable_configuration = config
        
        # Set up embedding columns if needed
        setup_embedding_columns(config)
        
        # Set up vector search scopes
        setup_vector_search_scopes(config)
        
        # Include search interface
        extend VectorSearchInterface
        include EmbeddingInterface
      end

      private

      def setup_embedding_columns(config)
        config.embedding_fields.each do |field, options|
          # Define methods for accessing embeddings
          define_method "#{field}_embedding" do
            embeddings_cache[field] ||= generate_embedding_for(field, options)
          end
          
          define_method "#{field}_embedding=" do |vector|
            embeddings_cache[field] = vector
            store_embedding(field, vector)
          end
        end
      end

      def setup_vector_search_scopes(config)
        # Semantic similarity search
        scope :similar_to, ->(embedding, limit: 10) {
          nearest_neighbors(:embedding, embedding, distance: "cosine")
            .limit(limit)
        }
        
        # Hybrid search combining vector and keyword
        scope :hybrid_search, ->(query, embedding, alpha: 0.5) {
          keyword_results = search(query)
          vector_results = similar_to(embedding)
          
          # Combine and rerank results
          combine_search_results(keyword_results, vector_results, alpha)
        }
      end
    end

    # Vector search interface for ActiveSupervisor monitoring
    module VectorSearchInterface
      # Semantic search using embeddings
      def semantic_search(query, limit: 10, threshold: 0.8)
        query_embedding = generate_query_embedding(query)
        
        nearest_neighbors(:embedding, query_embedding, distance: "cosine")
          .where("embedding <=> ? < ?", query_embedding, 1 - threshold)
          .limit(limit)
      end

      # Find related contexts by similarity
      def find_related(context, limit: 5)
        return none unless context.respond_to?(:embedding) && context.embedding.present?
        
        where.not(id: context.id)
          .nearest_neighbors(:embedding, context.embedding, distance: "cosine")
          .limit(limit)
      end

      # Cluster similar contexts
      def cluster_by_similarity(num_clusters: 5)
        # Use HNSW index for efficient clustering
        all_embeddings = pluck(:id, :embedding).to_h
        
        # Perform clustering (simplified - would use proper clustering algorithm)
        clusters = {}
        all_embeddings.each do |id, embedding|
          cluster_id = find_nearest_cluster(embedding, clusters)
          clusters[cluster_id] ||= []
          clusters[cluster_id] << id
        end
        
        clusters
      end

      # Generate embeddings for all records (batch operation)
      def generate_all_embeddings(batch_size: 100)
        find_in_batches(batch_size: batch_size) do |batch|
          batch.each(&:generate_embeddings)
        end
      end

      private

      def generate_query_embedding(query)
        SolidAgent::EmbeddingService.generate(
          text: query,
          model: embedding_model,
          dimensions: embedding_dimensions
        )
      end

      def combine_search_results(keyword_results, vector_results, alpha)
        # Weighted combination of keyword and vector search
        combined_scores = {}
        
        keyword_results.each_with_index do |result, idx|
          combined_scores[result.id] ||= 0
          combined_scores[result.id] += (1 - alpha) * (1.0 / (idx + 1))
        end
        
        vector_results.each_with_index do |result, idx|
          combined_scores[result.id] ||= 0
          combined_scores[result.id] += alpha * (1.0 / (idx + 1))
        end
        
        # Sort by combined score and return records
        sorted_ids = combined_scores.sort_by { |_, score| -score }.map(&:first)
        where(id: sorted_ids).index_by(&:id).values_at(*sorted_ids).compact
      end
    end

    # Embedding generation and management
    module EmbeddingInterface
      def generate_embeddings
        return unless searchable_configuration.embedding_fields.any?
        
        searchable_configuration.embedding_fields.each do |field, options|
          text = extract_text_for_embedding(field)
          next if text.blank?
          
          embedding = SolidAgent::EmbeddingService.generate(
            text: text,
            model: options[:model] || embedding_model,
            dimensions: options[:dimensions] || embedding_dimensions
          )
          
          store_embedding(field, embedding)
        end
      end

      def store_embedding(field, vector)
        if field == :primary || field == :embedding
          # Store in main embedding column
          update_column(:embedding, vector) if respond_to?(:embedding=)
        else
          # Store in separate embeddings table
          message_embeddings.find_or_create_by(field: field.to_s).update!(
            embedding: vector,
            model: embedding_model,
            dimensions: vector.size
          )
        end
      end

      def embeddings_cache
        @embeddings_cache ||= {}
      end

      def extract_text_for_embedding(field)
        case field
        when :messages
          # Combine all messages for context embedding
          return "" unless respond_to?(:contextual_messages)
          
          contextual_messages.map do |msg|
            extract_message_content(msg)
          end.join("\n")
        when :summary
          # Use AI to generate summary if not present
          summary || generate_summary
        when :content
          # Direct content field
          respond_to?(:content) ? content : to_s
        else
          # Try to call the field as a method
          respond_to?(field) ? send(field).to_s : ""
        end
      end

      def extract_message_content(message)
        if message.respond_to?(:content)
          message.content
        elsif message.respond_to?(:body)
          message.body
        elsif message.respond_to?(:text)
          message.text
        else
          message.to_s
        end
      end

      def generate_summary
        # Use AI to generate a summary of the context
        return "" unless respond_to?(:contextual_messages)
        
        messages_text = contextual_messages.first(10).map do |msg|
          extract_message_content(msg)
        end.join("\n")
        
        return "" if messages_text.blank?
        
        # This would call an AI service to summarize
        SolidAgent::SummaryService.generate(messages_text)
      rescue => e
        Rails.logger.error "Failed to generate summary: #{e.message}"
        ""
      end

      def should_generate_embeddings?
        searchable_configuration.embedding_fields.any? &&
        (saved_change_to_attribute?(:content) || 
         saved_change_to_attribute?(:updated_at))
      end

      def should_update_search?
        should_generate_embeddings?
      end

      def update_search_index
        # Update any external search indices (Elasticsearch, Algolia, etc.)
        SearchIndexJob.perform_later(self.class.name, id) if defined?(SearchIndexJob)
      end

      # For monitoring and debugging
      def embedding_similarity_to(other)
        return nil unless embedding.present? && other.embedding.present?
        
        # Cosine similarity
        dot_product = embedding.zip(other.embedding).map { |a, b| a * b }.sum
        norm_a = Math.sqrt(embedding.map { |x| x**2 }.sum)
        norm_b = Math.sqrt(other.embedding.map { |x| x**2 }.sum)
        
        dot_product / (norm_a * norm_b)
      end
    end

    # Configuration for searchable behavior
    class SearchableConfiguration
      attr_reader :embedding_fields, :search_indices

      def initialize
        @embedding_fields = {}
        @search_indices = {}
      end

      def embed(field, model: nil, dimensions: nil)
        @embedding_fields[field] = {
          model: model,
          dimensions: dimensions
        }.compact
      end

      def index(name, &block)
        index_config = SearchIndexConfiguration.new
        index_config.instance_eval(&block) if block_given?
        @search_indices[name] = index_config
      end
    end

    class SearchIndexConfiguration
      attr_reader :fields

      def initialize
        @fields = []
      end

      def field(name, weight: 1.0)
        @fields << { name: name, weight: weight }
      end
    end
  end

  # Service for generating embeddings
  class EmbeddingService
    class << self
      def generate(text:, model: "text-embedding-3-small", dimensions: 1536)
        # Cache embeddings to avoid regenerating
        cache_key = "embedding:#{Digest::SHA256.hexdigest(text)}:#{model}:#{dimensions}"
        
        Rails.cache.fetch(cache_key, expires_in: 1.week) do
          case model
          when /^text-embedding/
            generate_openai_embedding(text, model, dimensions)
          when /^voyage/
            generate_voyage_embedding(text, model, dimensions)
          when /^cohere/
            generate_cohere_embedding(text, model, dimensions)
          else
            generate_ollama_embedding(text, model, dimensions)
          end
        end
      end

      private

      def generate_openai_embedding(text, model, dimensions)
        client = OpenAI::Client.new
        response = client.embeddings(
          parameters: {
            model: model,
            input: text,
            dimensions: dimensions
          }
        )
        response.dig("data", 0, "embedding")
      end

      def generate_voyage_embedding(text, model, dimensions)
        # Voyage AI implementation
        []
      end

      def generate_cohere_embedding(text, model, dimensions)
        # Cohere implementation
        []
      end

      def generate_ollama_embedding(text, model, dimensions)
        # Ollama local embedding
        []
      end
    end
  end

  # Summary generation service
  class SummaryService
    class << self
      def generate(text, max_length: 200)
        # This would use an AI model to generate summaries
        # Simplified implementation
        text.truncate(max_length)
      end
    end
  end
end