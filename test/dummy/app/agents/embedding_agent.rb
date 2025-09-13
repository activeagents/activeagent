# frozen_string_literal: true

# Example agent for generating embeddings using local models
class EmbeddingAgent < ApplicationAgent
  # Use class-level configuration for consistent embedding model
  generate_with :onnx_embedding
  
  # Or configure inline
  def self.configure_embedding_provider(provider = :onnx)
    case provider
    when :onnx
      generate_with({
        "service" => "OnnxRuntime",
        "model_type" => "embedding",
        "model" => "Xenova/all-MiniLM-L6-v2",
        "model_source" => "huggingface",
        "use_informers" => true,
        "cache_dir" => Rails.root.join("tmp", "models", "embeddings").to_s
      })
    when :transformers
      generate_with({
        "service" => "Transformers",
        "model_type" => "embedding",
        "model" => "sentence-transformers/all-mpnet-base-v2",
        "model_source" => "huggingface",
        "task" => "feature-extraction",
        "cache_dir" => Rails.root.join("tmp", "models", "embeddings").to_s
      })
    end
  end
  
  # Generate embeddings for a single text
  def embed_text
    @text = params[:text] || "Default text for embedding"
    embed prompt: @text
  end
  
  # Generate embeddings for multiple texts (batch processing)
  def batch_embed
    texts = params[:texts] || ["First text", "Second text", "Third text"]
    
    embeddings = texts.map do |text|
      response = embed(prompt: text)
      {
        text: text,
        embedding: response.message.content,
        dimensions: response.message.content.size
      }
    end
    
    # Return all embeddings
    {
      embeddings: embeddings,
      model: self.class.generation_provider_name,
      timestamp: Time.current
    }
  end
  
  # Compute similarity between two texts using embeddings
  def compute_similarity
    text1 = params[:text1] || "The cat sat on the mat"
    text2 = params[:text2] || "A feline rested on the rug"
    
    # Generate embeddings for both texts
    embedding1 = embed(prompt: text1).message.content
    embedding2 = embed(prompt: text2).message.content
    
    # Compute cosine similarity
    similarity = cosine_similarity(embedding1, embedding2)
    
    {
      text1: text1,
      text2: text2,
      similarity: similarity,
      similar: similarity > 0.7 ? "Very similar" : similarity > 0.4 ? "Somewhat similar" : "Not similar"
    }
  end
  
  # Semantic search using embeddings
  def semantic_search
    query = params[:query] || "Find documents about machine learning"
    documents = params[:documents] || default_documents
    top_k = params[:top_k] || 3
    
    # Generate query embedding
    query_embedding = embed(prompt: query).message.content
    
    # Generate embeddings for all documents and compute similarities
    results = documents.map do |doc|
      doc_embedding = embed(prompt: doc[:content]).message.content
      similarity = cosine_similarity(query_embedding, doc_embedding)
      
      {
        document: doc,
        similarity: similarity
      }
    end
    
    # Sort by similarity and return top-k
    top_results = results.sort_by { |r| -r[:similarity] }.first(top_k)
    
    {
      query: query,
      results: top_results,
      model: self.class.generation_provider_name
    }
  end
  
  # Store embeddings in database (with Active Record)
  def store_embedding
    text = params[:text]
    metadata = params[:metadata] || {}
    
    # Generate embedding
    response = embed(prompt: text)
    embedding = response.message.content
    
    # Store in database (assuming you have an Embedding model)
    if defined?(Embedding)
      embedding_record = Embedding.create!(
        text: text,
        vector: embedding, # Assumes you're using pgvector or similar
        dimensions: embedding.size,
        model_name: self.class.generation_provider_name,
        metadata: metadata
      )
      
      { id: embedding_record.id, status: "stored" }
    else
      # Return embedding without storing
      {
        text: text,
        embedding: embedding,
        dimensions: embedding.size,
        status: "not_stored",
        note: "Embedding model not available"
      }
    end
  end
  
  private
  
  def cosine_similarity(vec1, vec2)
    return 0.0 if vec1.size != vec2.size
    
    dot_product = vec1.zip(vec2).map { |a, b| a * b }.sum
    magnitude1 = Math.sqrt(vec1.map { |a| a**2 }.sum)
    magnitude2 = Math.sqrt(vec2.map { |a| a**2 }.sum)
    
    return 0.0 if magnitude1 == 0 || magnitude2 == 0
    
    dot_product / (magnitude1 * magnitude2)
  end
  
  def default_documents
    [
      {
        id: 1,
        title: "Introduction to Machine Learning",
        content: "Machine learning is a subset of artificial intelligence that enables systems to learn from data."
      },
      {
        id: 2,
        title: "Deep Learning Fundamentals",
        content: "Deep learning uses neural networks with multiple layers to progressively extract features from raw input."
      },
      {
        id: 3,
        title: "Natural Language Processing",
        content: "NLP is a field of AI that helps computers understand, interpret, and manipulate human language."
      },
      {
        id: 4,
        title: "Computer Vision Basics",
        content: "Computer vision enables machines to interpret and understand visual information from the world."
      },
      {
        id: 5,
        title: "Reinforcement Learning",
        content: "Reinforcement learning is a type of machine learning where agents learn to make decisions through trial and error."
      }
    ]
  end
end