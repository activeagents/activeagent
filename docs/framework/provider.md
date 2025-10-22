# Provider

Providers are the backbone of the Active Agent framework, allowing seamless integration with various AI services. They provide a consistent interface for prompting and generating responses, making it easy to switch between different providers without changing the core logic of your application.

## Available Providers
You can use the following providers with Active Agent:
::: code-group

<<< @/../test/dummy/app/agents/providers/open_ai_agent.rb{ruby:line-numbers} [OpenAI]

<<< @/../test/dummy/app/agents/providers/anthropic_agent.rb{ruby:line-numbers} [Anthropic]

<<< @/../test/dummy/app/agents/providers/open_router_agent.rb{ruby:line-numbers} [OpenRouter]

<<< @/../test/dummy/app/agents/providers/ollama_agent.rb{ruby:line-numbers} [Ollama]

<<< @/../test/dummy/app/agents/providers/mock_agent.rb{ruby:line-numbers} [Mock]
:::

## Response
Providers handle the request-response cycle for generating responses based on the provided prompts. They process the prompt context, including messages, actions, and parameters, and return the generated response.

### Response Object
The `ActiveAgent::Providers::Response` class encapsulates the result of a generation request, providing access to both the processed response and debugging information.

#### Attributes

- **`message`** - The generated response message from the AI provider
- **`prompt`** - The complete prompt object used for generation, including updated context, messages, and parameters
- **`raw_response`** - The unprocessed response data from the AI provider, useful for debugging and accessing provider-specific metadata

#### Example Usage

<<< @/../test/generation_provider_examples_test.rb#generation_response_usage{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/generation-provider-examples-test.rb-test-response-object-usage.md -->
:::
The response object ensures you have full visibility into both the input prompt context and the raw provider response, making it easy to debug generation issues or access provider-specific response metadata.

## Provider Configuration

You can configure providers with custom settings:

### Model and Temperature Configuration

<<< @/../test/generation_provider_examples_test.rb#anthropic_provider_example{ruby:line-numbers}

<<< @/../test/generation_provider_examples_test.rb#google_provider_example{ruby:line-numbers}

### Custom Host Configuration

For Azure OpenAI or other custom endpoints:

<<< @/../test/generation_provider_examples_test.rb#custom_host_configuration{ruby:line-numbers}

## Configuration Precedence

ActiveAgent follows a clear hierarchy for configuration parameters, ensuring that you have fine-grained control over your AI generation settings. Parameters can be configured at multiple levels, with higher-priority settings overriding lower-priority ones.

### Precedence Order (Highest to Lowest)

1. **Runtime Options** - Parameters passed directly to the `prompt` method
2. **Agent Options** - Parameters defined in `generate_with` at the agent class level
3. **Global Configuration** - Parameters in `config/active_agent.yml`

This hierarchy allows you to:
- Set sensible defaults globally
- Override them for specific agents
- Make runtime adjustments for individual requests

### Example: Configuration Precedence in Action

Configuration can be set at three levels, with runtime options taking highest precedence:

```ruby
# 1. Global configuration (config/active_agent.yml)
# providers:
#   openai:
#     model: "gpt-3.5-turbo"
#     temperature: 0.7

# 2. Agent-level configuration
class MyAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",      # Overrides global model
    temperature: 0.5           # Overrides global temperature

  def analyze
    # 3. Runtime configuration (highest precedence)
    prompt(
      model: "gpt-4o",         # Overrides agent-level model
      temperature: 0.9         # Overrides agent-level temperature
    )
  end
end
```

### Data Collection Precedence Example

The `data_collection` parameter for OpenRouter follows the same precedence rules:

```ruby
# Global: data_collection = "allow"
# Agent: data_collection = "deny"

class PrivateAgent < ApplicationAgent
  generate_with :open_router,
    model: "openai/gpt-4o",
    data_collection: "deny"    # Overrides global setting

  def secure_prompt
    prompt(
      data_collection: "allow"  # Runtime overrides agent setting
    )
  end
end
```

### Key Principles

#### 1. Runtime Always Wins
Runtime options in the `prompt` method override all other configurations:

```ruby
class FlexibleAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini"

  def creative_response
    prompt(temperature: 1.0)  # High creativity
  end

  def precise_response
    prompt(temperature: 0.1)  # Low creativity, more deterministic
  end
end
```

#### 2. Nil Values Don't Override
Nil values passed at runtime don't override existing configurations:

```ruby
class ConsistentAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o", temperature: 0.7

  def analyze
    prompt(temperature: nil)  # Doesn't override, uses 0.7
  end
end
```

#### 3. Agent Configuration Overrides Global
Agent-level settings take precedence over global configuration files:

```ruby
# config/active_agent.yml
# providers:
#   openai:
#     model: "gpt-3.5-turbo"

class SpecializedAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"  # Overrides global setting

  def analyze
    prompt  # Uses gpt-4o, not gpt-3.5-turbo
  end
end
```

### Supported Runtime Options

The following options can be overridden at runtime:

- `:model` - The AI model to use
- `:temperature` - Creativity/randomness (0.0-1.0)
- `:max_tokens` - Maximum response length
- `:stream` - Enable streaming responses
- `:top_p` - Nucleus sampling parameter
- `:frequency_penalty` - Reduce repetition
- `:presence_penalty` - Encourage topic diversity
- `:response_format` - Structured output format
- `:seed` - For reproducible outputs
- `:stop` - Stop sequences
- `:tools_choice` - Tool selection strategy
- `:data_collection` - Privacy settings (OpenRouter)
- `:require_parameters` - Provider parameter validation (OpenRouter)

### Best Practices

1. **Use Global Config for Defaults**: Set organization-wide defaults in `config/active_agent.yml`
2. **Agent-Level for Specific Needs**: Override in `generate_with` for agent-specific requirements
3. **Runtime for Dynamic Adjustments**: Use runtime options for user preferences or conditional logic

## Embeddings Support

Providers support creating text embeddings for semantic search, clustering, and similarity matching. Embeddings transform text into numerical vectors that capture semantic meaning.

### Generating Embeddings Synchronously

Use `embed_now` to generate embeddings immediately:

<<< @/../test/agents/embedding_agent_test.rb#embedding_sync_generation{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-generates-embeddings-synchronously-with-embed-now.md -->
:::

### Asynchronous Embedding Generation

Use `embed_later` for background processing of embeddings:

<<< @/../test/agents/embedding_agent_test.rb#embedding_async_generation{ruby:line-numbers}

### Embedding Callbacks

Process embeddings with before and after callbacks:

<<< @/../test/agents/embedding_agent_test.rb#embedding_with_callbacks{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-processes-embeddings-with-callbacks.md -->
:::

### Similarity Search

Use embeddings to find semantically similar content:

<<< @/../test/agents/embedding_agent_test.rb#embedding_similarity_search{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-performs-similarity-search-with-embeddings.md -->
:::

### Provider-Specific Embedding Models

Different providers offer various embedding models:

- **OpenAI**: `text-embedding-3-large`, `text-embedding-3-small`, `text-embedding-ada-002`
- **Ollama**: `nomic-embed-text`, `mxbai-embed-large`, `all-minilm`
- **Anthropic**: Does not natively support embeddings (use a dedicated embedding provider)

### Configuration

Configure embedding models in your agent:

```ruby
class EmbeddingAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4",  # For text generation
    embedding_model: "text-embedding-3-large"  # For embeddings
end
```

Or in your configuration file:

```yaml
development:
  openai:
    model: gpt-4
    embedding_model: text-embedding-3-large
    dimensions: 256  # Optional: reduce embedding dimensions
```

For more details on embeddings, see the [Embeddings Guide](/framework/embeddings).

## Provider-Specific Documentation

For detailed documentation on specific providers and their features:

- [OpenAI Provider](/providers/openai-provider) - GPT-4, GPT-3.5, function calling, vision, and Azure OpenAI support
- [Anthropic Provider](/providers/anthropic-provider) - Claude 3.5 and Claude 3 models with extended context windows
- [Ollama Provider](/providers/ollama-provider) - Local LLM inference for privacy-sensitive applications
- [OpenRouter Provider](/providers/open-router-provider) - Multi-model routing with fallbacks, PDF processing, and vision support
- [Mock Provider](/providers/mock-provider) - Testing provider for development without API costs

