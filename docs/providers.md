# Providers

Providers are the backbone of the Active Agent framework, allowing seamless integration with various AI services. They provide a consistent interface for prompting and generating responses, making it easy to switch between different providers without changing the core logic of your application.

## Available Providers
You can use the following providers with Active Agent:
::: code-group

<<< @/../test/dummy/app/agents/providers/anthropic_agent.rb#agent{ruby} [Anthropic]

<<< @/../test/dummy/app/agents/providers/ollama_agent.rb#agent{ruby} [Ollama]

<<< @/../test/dummy/app/agents/providers/open_ai_agent.rb#agent{ruby} [OpenAI]

<<< @/../test/dummy/app/agents/providers/open_router_agent.rb#agent{ruby} [OpenRouter]

<<< @/../test/dummy/app/agents/providers/mock_agent.rb#agent{ruby} [Mock]
:::

## Provider-Specific Documentation

For detailed documentation on specific providers and their features:

- [OpenAI Provider](/providers/openai-provider) - GPT-4, GPT-3.5, function calling, vision, and Azure OpenAI support
- [Anthropic Provider](/providers/anthropic-provider) - Claude 3.5 and Claude 3 models with extended context windows
- [Ollama Provider](/providers/ollama-provider) - Local LLM inference for privacy-sensitive applications
- [OpenRouter Provider](/providers/open-router-provider) - Multi-model routing with fallbacks, PDF processing, and vision support
- [Mock Provider](/providers/mock-provider) - Testing provider for development without API costs

## Configuration

ActiveAgent applies configuration in a clear hierarchy, with settings closer to execution taking precedence:

1. **Runtime Options** - Parameters in `prompt` method (highest priority)
2. **Agent Options** - Parameters in `generate_with`
3. **Global Configuration** - Parameters in `config/active_agent.yml`

```ruby
# Global: temperature: 0.7 (config/active_agent.yml)

class MyAgent < ApplicationAgent
  generate_with :openai, temperature: 0.5  # Overrides global

  def analyze
    prompt(temperature: 0.9)  # Overrides agent-level
  end
end
```

For detailed configuration precedence rules, environment-specific settings, and best practices, see **[Configuration](/framework/configuration)**.

## Response Objects

Providers return specialized response objects that encapsulate generation results, usage statistics, and debugging information. ActiveAgent provides two response types depending on the operation:

### Prompt Response

The `ActiveAgent::Providers::Common::PromptResponse` class encapsulates conversational/completion responses from `generate_now` operations.

#### Attributes

- **`message`** - The most recent message in the conversation
- **`messages`** - The complete list of messages from the conversation
- **`context`** - The original request context sent to the provider
- **`raw_request`** - The provider-formatted API request for debugging
- **`raw_response`** - The unprocessed API response with provider-specific metadata
- **`usage`** - Token usage statistics hash with `prompt_tokens`, `completion_tokens`, and `total_tokens`
- **`prompt_tokens`** - Number of tokens in the input
- **`completion_tokens`** - Number of tokens in the output
- **`total_tokens`** - Total tokens used (prompt + completion)

#### Example Usage

<<< @/../test/docs/framework/providers_examples_test.rb#generation_response_usage{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/providers-examples-test.rb-test-response-object-usage.md -->
:::

### Embed Response

The `ActiveAgent::Providers::Common::EmbedResponse` class encapsulates embedding responses from `embed_now` operations.

#### Attributes

- **`data`** - Array of embedding objects with vector data
- **`context`** - The original request context sent to the provider
- **`raw_request`** - The provider-formatted API request for debugging
- **`raw_response`** - The unprocessed API response with provider-specific metadata
- **`usage`** - Token usage statistics hash (format varies by provider)
- **`prompt_tokens`** - Number of tokens processed for embeddings

#### Key Differences from Prompt Response

- **No `message` or `messages`**: Embeddings return vector data, not conversational messages
- **`data` attribute**: Contains the embedding vectors as arrays of floats
- **Usage statistics**: Only tracks input tokens (`prompt_tokens`), no completion tokens

#### Example Structure

```ruby
response = generation.embed_now

# Access embedding vector data
embedding_vector = response.data.first[:embedding]  # Array of floats

# Check usage statistics
tokens_used = response.prompt_tokens

# Inspect raw API response
raw_data = response.raw_response
```

The response objects ensure you have full visibility into both the input context and the raw provider response, making it easy to debug generation issues or access provider-specific response metadata.

## Embeddings

Providers support generating text embeddings for semantic search, clustering, and similarity matching. Use `embed_now` for synchronous embedding generation or `embed_later` for background processing.

```ruby
class EmbeddingAgent < ApplicationAgent
  embed_with :openai, embedding_model: "text-embedding-3-large"
end

# Generate embeddings
response = EmbeddingAgent.embed(input: "Sample text").embed_now
vector = response.data.first[:embedding]  # Array of floats
```

For comprehensive embedding documentation including similarity search, batch processing, provider-specific models, and advanced patterns, see **[Embeddings](/agents/embeddings)**.
