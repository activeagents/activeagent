# Embeddings

Embeddings are numerical representations of text that capture semantic meaning, enabling similarity searches, clustering, and other vector-based operations. ActiveAgent provides a unified interface for generating embeddings across all supported providers.

## Overview

Embeddings transform text into high-dimensional vectors that represent semantic meaning. Similar texts produce similar vectors, enabling powerful features like:

- **Semantic Search** - Find related content by meaning, not just keywords
- **Clustering** - Group similar documents automatically
- **Classification** - Categorize text based on similarity to examples
- **Recommendation** - Suggest related content based on embeddings
- **Anomaly Detection** - Identify outliers in text data

## Basic Usage

### Generating Embeddings

Use the `embed_now` method to generate embeddings synchronously:

<<< @/../test/agents/embedding_agent_test.rb#embedding_sync_generation {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-generates-embeddings-synchronously-with-embed-now.md -->
:::

### Async Embeddings

Generate embeddings in background jobs:

<<< @/../test/agents/embedding_agent_test.rb#embedding_async_generation {ruby:line-numbers}

## Embedding Callbacks

Use callbacks to process embeddings before and after generation:

<<< @/../test/agents/embedding_agent_test.rb#embedding_with_callbacks {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-processes-embeddings-with-callbacks.md -->
:::

## Provider Configuration

Each provider supports different embedding models and configurations:

### OpenAI

Configure OpenAI-specific embedding models:

<<< @/../test/agents/embedding_agent_test.rb#embedding_openai_model_config {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-uses-configured-openai-embedding-model.md -->
:::

### Ollama

Configure Ollama for local embedding generation:

<<< @/../test/agents/embedding_agent_test.rb#embedding_ollama_provider_test {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-generates-embeddings-with-Ollama-provider.md -->
:::

### Error Handling

ActiveAgent provides proper error handling for connection issues:

<<< @/../test/generation_provider/ollama_provider_test.rb#ollama_provider_embed {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/ollama-provider-test.rb-test-embed-method-works-with-ollama-provider.md -->
:::

## Working with Embeddings

### Similarity Search

Find similar documents using cosine similarity:

<<< @/../test/agents/embedding_agent_test.rb#embedding_similarity_search {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-performs-similarity-search-with-embeddings.md -->
:::

### Batch Processing

Process multiple embeddings efficiently:

<<< @/../test/agents/embedding_agent_test.rb#embedding_batch_processing {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-processes-multiple-embeddings-in-batch.md -->
:::

### Embedding Dimensions

Different models produce different embedding dimensions:

<<< @/../test/agents/embedding_agent_test.rb#embedding_dimension_test {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-verifies-embedding-dimensions-for-different-models.md -->
:::

## Advanced Patterns

### Caching Embeddings

Cache embeddings to avoid regenerating them:

```ruby
class CachedEmbeddingAgent < ApplicationAgent
  def get_embedding(text)
    cache_key = "embedding:#{Digest::SHA256.hexdigest(text)}"
    
    Rails.cache.fetch(cache_key, expires_in: 30.days) do
      generation = self.class.with(message: text).prompt_context
      generation.embed_now.message.content
    end
  end
end
```

### Multi-Model Embeddings

Use different models for different purposes:

```ruby
class MultiModelEmbeddingAgent < ApplicationAgent
  def generate_semantic_embedding(text)
    # High-quality semantic embedding
    self.class.generate_with :openai, 
      embedding_model: "text-embedding-3-large"
    
    generation = self.class.with(message: text).prompt_context
    generation.embed_now
  end
  
  def generate_fast_embedding(text)
    # Faster, smaller embedding for real-time use
    self.class.generate_with :openai,
      embedding_model: "text-embedding-3-small"
    
    generation = self.class.with(message: text).prompt_context
    generation.embed_now
  end
end
```

## Vector Databases

Store and query embeddings using vector databases:

### PostgreSQL with pgvector

```ruby
class PgVectorAgent < ApplicationAgent
  def store_document(text)
    # Generate embedding
    generation = self.class.with(message: text).prompt_context
    embedding = generation.embed_now.message.content
    
    # Store in PostgreSQL with pgvector
    Document.create!(
      content: text,
      embedding: embedding  # pgvector column
    )
  end
  
  def search_similar(query, limit: 10)
    query_embedding = get_embedding(query)
    
    # Use pgvector's <-> operator for cosine distance
    Document
      .order(Arel.sql("embedding <-> '#{query_embedding}'"))
      .limit(limit)
  end
end
```

### Pinecone Integration

```ruby
class PineconeAgent < ApplicationAgent
  def initialize
    super
    @pinecone = Pinecone::Client.new(api_key: ENV['PINECONE_API_KEY'])
    @index = @pinecone.index('documents')
  end
  
  def upsert_document(id, text, metadata = {})
    embedding = get_embedding(text)
    
    @index.upsert(
      vectors: [{
        id: id,
        values: embedding,
        metadata: metadata.merge(text: text)
      }]
    )
  end
  
  def query_similar(text, top_k: 10)
    embedding = get_embedding(text)
    
    @index.query(
      vector: embedding,
      top_k: top_k,
      include_metadata: true
    )
  end
end
```

## Testing Embeddings

Test embedding functionality with comprehensive test coverage including callbacks, similarity search, and batch processing as shown in the examples above.

## Performance Optimization

### Batch Processing

Process embeddings in batches for better performance:

```ruby
class BatchOptimizedAgent < ApplicationAgent
  def process_documents(documents)
    documents.each_slice(100) do |batch|
      Parallel.each(batch, in_threads: 5) do |doc|
        generation = self.class.with(message: doc.content).prompt_context
        doc.embedding = generation.embed_now.message.content
        doc.save!
      end
    end
  end
end
```

### Caching Strategy

Implement intelligent caching:

```ruby
class SmartCacheAgent < ApplicationAgent
  def get_or_generate_embedding(text)
    # Check cache first
    cached = fetch_from_cache(text)
    return cached if cached
    
    # Generate if not cached
    embedding = generate_embedding(text)
    
    # Cache based on text length and importance
    if should_cache?(text)
      cache_embedding(text, embedding)
    end
    
    embedding
  end
  
  private
  
  def should_cache?(text)
    text.length > 100 || text.include?("important")
  end
end
```

## Best Practices

1. **Choose the Right Model** - Balance quality, speed, and cost
2. **Normalize Text** - Preprocess consistently before embedding
3. **Cache Aggressively** - Embeddings are expensive to generate
4. **Batch When Possible** - Process multiple texts together
5. **Monitor Dimensions** - Different models produce different sizes
6. **Use Callbacks** - Process embeddings consistently
7. **Handle Failures** - Implement retry logic and fallbacks
8. **Version Embeddings** - Track which model generated each embedding

## Common Use Cases

### Semantic Search

```ruby
class SemanticSearchAgent < ApplicationAgent
  def build_search_index(documents)
    documents.each do |doc|
      generation = self.class.with(message: doc.content).prompt_context
      doc.update!(embedding: generation.embed_now.message.content)
    end
  end
  
  def search(query)
    query_embedding = get_embedding(query)
    
    Document
      .select("*, embedding <-> '#{query_embedding}' as distance")
      .order("distance")
      .limit(10)
  end
end
```

### Content Recommendations

```ruby
class RecommendationAgent < ApplicationAgent
  def recommend_similar(article)
    article_embedding = article.embedding || generate_embedding(article.content)
    
    Article
      .where.not(id: article.id)
      .select("*, embedding <-> '#{article_embedding}' as similarity")
      .order("similarity")
      .limit(5)
  end
end
```

### Clustering

```ruby
class ClusteringAgent < ApplicationAgent
  def cluster_documents(documents, num_clusters: 5)
    # Generate embeddings
    embeddings = documents.map do |doc|
      get_embedding(doc.content)
    end
    
    # Use k-means or other clustering algorithm
    clusters = perform_clustering(embeddings, num_clusters)
    
    # Assign documents to clusters
    documents.zip(clusters).each do |doc, cluster_id|
      doc.update!(cluster_id: cluster_id)
    end
  end
end
```

## Troubleshooting

### Common Issues

1. **Dimension Mismatch** - Ensure all embeddings use the same model
2. **Memory Issues** - Large embedding vectors can consume significant RAM
3. **Rate Limits** - Implement exponential backoff for API limits
4. **Cost Management** - Monitor embedding API usage and costs
5. **Connection Errors** - Handle network issues with Ollama and other providers

### Debugging

```ruby
class DebuggingAgent < ApplicationAgent
  def debug_embedding(text)
    generation = self.class.with(message: text).prompt_context
    
    Rails.logger.info "Generating embedding for: #{text[0..100]}..."
    Rails.logger.info "Provider: #{generation_provider.class.name}"
    Rails.logger.info "Model: #{generation_provider.embedding_model}"
    
    response = generation.embed_now
    embedding = response.message.content
    
    Rails.logger.info "Dimensions: #{embedding.size}"
    Rails.logger.info "Range: [#{embedding.min}, #{embedding.max}]"
    Rails.logger.info "Mean: #{embedding.sum / embedding.size}"
    
    embedding
  end
end
```

## Related Documentation

- [Generation Provider Overview](/docs/framework/generation-provider)
- [OpenAI Provider](/docs/generation-providers/openai-provider)
- [Ollama Provider](/docs/generation-providers/ollama-provider)
- [Callbacks](/docs/active-agent/callbacks)
- [Generation](/docs/active-agent/generation)