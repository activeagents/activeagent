---
title: RubyLLM Provider
description: Unified access to 15+ LLM providers through the RubyLLM gem. Use OpenAI, Anthropic, Gemini, Bedrock, Azure, Ollama, and more with a single provider configuration.
---
# {{ $frontmatter.title }}

The RubyLLM provider gives your agents access to 15+ LLM providers through [RubyLLM](https://rubyllm.com)'s unified API. Switch between OpenAI, Anthropic, Gemini, Bedrock, Azure, Ollama, and more by changing the model parameter.

## Configuration

### Basic Setup

Configure RubyLLM in your agent:

```ruby
class MyAgent < ApplicationAgent
  generate_with :ruby_llm, model: "gpt-4o-mini"
end
```

### RubyLLM API Keys

RubyLLM manages its own API keys. Configure them in an initializer:

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.openai_api_key = Rails.application.credentials.dig(:openai, :api_key)
  config.anthropic_api_key = Rails.application.credentials.dig(:anthropic, :api_key)
  config.gemini_api_key = Rails.application.credentials.dig(:gemini, :api_key)
  # Add keys for any providers you want to use
end
```

### Configuration File

Set up RubyLLM in `config/active_agent.yml`:

```yaml
ruby_llm: &ruby_llm
  service: "RubyLLM"

development:
  ruby_llm:
    <<: *ruby_llm

production:
  ruby_llm:
    <<: *ruby_llm
```

## Supported Models

RubyLLM automatically resolves which provider to use based on the model ID. Any model supported by RubyLLM works with this provider. For the complete list, see [RubyLLM's documentation](https://rubyllm.com).

### Examples by Provider

| Provider | Example Models |
|----------|---------------|
| **OpenAI** | `gpt-4o`, `gpt-4o-mini`, `gpt-4.1` |
| **Anthropic** | `claude-sonnet-4-5-20250929`, `claude-haiku-4-5` |
| **Google Gemini** | `gemini-2.0-flash`, `gemini-1.5-pro` |
| **AWS Bedrock** | Bedrock-hosted models |
| **Azure OpenAI** | Azure-hosted OpenAI models |
| **Ollama** | `llama3`, `mistral`, locally-hosted models |

Switch providers by changing the model:

```ruby
class FlexibleAgent < ApplicationAgent
  # Any of these work with the same provider config:
  generate_with :ruby_llm, model: "gpt-4o-mini"
  # generate_with :ruby_llm, model: "claude-sonnet-4-5-20250929"
  # generate_with :ruby_llm, model: "gemini-2.0-flash"
end
```

## Provider-Specific Parameters

### Required Parameters

- **`model`** - Model identifier (e.g., "gpt-4o-mini", "claude-sonnet-4-5-20250929")

### Sampling Parameters

- **`temperature`** - Controls randomness (0.0 to 1.0)
- **`max_tokens`** - Maximum number of tokens to generate (passed via RubyLLM's `params:` merge)

### Client Configuration

Configure timeouts and other settings through RubyLLM directly:

```ruby
RubyLLM.configure do |config|
  config.request_timeout = 120
end
```

## Tool Calling

RubyLLM supports tool/function calling for models that support it. Use the standard ActiveAgent tool format:

```ruby
class WeatherAgent < ApplicationAgent
  generate_with :ruby_llm, model: "gpt-4o-mini"

  def forecast
    prompt(
      message: "What's the weather in Boston?",
      tools: [{
        name: "get_weather",
        description: "Get weather for a location",
        parameters: {
          type: "object",
          properties: {
            location: { type: "string", description: "City name" }
          },
          required: ["location"]
        }
      }]
    )
  end

  def get_weather(location:)
    WeatherService.fetch(location)
  end
end
```

## Embeddings

Generate embeddings through RubyLLM's unified embedding API:

```ruby
class SearchAgent < ApplicationAgent
  generate_with :ruby_llm, model: "gpt-4o-mini"
  embed_with :ruby_llm, model: "text-embedding-3-small"

  def index_document
    embed(input: "Document text to embed")
  end
end
```

## Streaming

Streaming is supported for models that support it:

```ruby
class StreamingAgent < ApplicationAgent
  generate_with :ruby_llm, model: "gpt-4o-mini", stream: true
end
```

See [Streaming](/agents/streaming) for ActionCable integration and real-time updates.

## When to Use RubyLLM vs Direct Providers

**Use RubyLLM when:**
- You want to switch between providers without changing configuration
- You prefer RubyLLM's key management via `RubyLLM.configure`
- You want access to providers that ActiveAgent doesn't have a dedicated implementation for (e.g., Gemini, Bedrock)
- You want a single gem dependency for multi-provider support

**Use a direct provider (OpenAI, Anthropic) when:**
- You need provider-specific features (MCP servers, extended thinking, JSON schema mode)
- You want the tightest integration with a provider's gem SDK
- You need provider-specific error handling classes

## Related Documentation

- [Providers Overview](/providers) - Compare all available providers
- [Getting Started](/getting_started) - Complete setup guide
- [Configuration](/framework/configuration) - Environment-specific settings
- [Tools](/actions/tools) - Function calling
- [Embeddings](/actions/embeddings) - Vector generation
- [Streaming](/agents/streaming) - Real-time response updates
- [RubyLLM Documentation](https://rubyllm.com) - Official RubyLLM docs
