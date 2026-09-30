---
title: RubyLLM Provider
description: Unified access to 15+ LLM providers through the RubyLLM gem. Use OpenAI, Anthropic, Gemini, Bedrock, Azure, Ollama, and more with a single provider configuration.
---
# {{ $frontmatter.title }}

The RubyLLM provider gives your agents access to 15+ LLM providers through [RubyLLM](https://rubyllm.com)'s unified API. Switch between OpenAI, Anthropic, Gemini, Bedrock, Azure, Ollama, and more by changing the model parameter.

## Configuration

### Installation

The provider supports ruby_llm 1.16 and 2.x. The minimum version prevents Bundler from selecting old releases such as 1.2, which lack the provider APIs the adapter needs:

```bash
bundle add ruby_llm --version ">= 1.16, < 3"
```

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
| **Anthropic** | `claude-sonnet-5`, `claude-haiku-4-5` |
| **Google Gemini** | `gemini-2.0-flash`, `gemini-1.5-pro` |
| **AWS Bedrock** | Bedrock-hosted models |
| **Azure OpenAI** | Azure-hosted OpenAI models |
| **Ollama** | `llama3`, `mistral`, locally-hosted models |

Switch providers by changing the model:

```ruby
class FlexibleAgent < ApplicationAgent
  # Any of these work with the same provider config:
  generate_with :ruby_llm, model: "gpt-4o-mini"
  # generate_with :ruby_llm, model: "claude-sonnet-5"
  # generate_with :ruby_llm, model: "gemini-2.0-flash"
end
```

### Pinning the Platform

When the same model ID is served by more than one of RubyLLM's providers, RubyLLM picks one by its own registry preference — `gemini-2.5-flash` resolves to the Gemini API even when you have configured Vertex AI credentials. Set `platform:` to pin the request to a specific RubyLLM provider; it maps to RubyLLM's own `provider:` option:

```ruby
class VertexAgent < ApplicationAgent
  generate_with :ruby_llm, model: "gemini-2.5-flash", platform: :vertexai
end
```

Or in `config/active_agent.yml`:

```yaml
production:
  ruby_llm:
    service: "RubyLLM"
    model: "gemini-2.5-flash"
    platform: "vertexai"
```

Authentication and region stay in RubyLLM's configuration:

```ruby
# config/initializers/ruby_llm.rb
RubyLLM.configure do |config|
  config.vertexai_project_id = "your-project-id"
  config.vertexai_location = "us-central1"
end
```

Valid values are RubyLLM's provider keys — `:openai`, `:anthropic`, `:gemini`, `:vertexai`, `:bedrock`, `:openrouter`, `:ollama`, and so on. Omitting `platform:` keeps RubyLLM's automatic model-based routing. The option applies to embeddings as well as prompts.

### Choosing the OpenAI Protocol

RubyLLM talks to OpenAI over more than one wire protocol. ruby_llm 1.16 used Chat Completions (`POST /v1/chat/completions`). **ruby_llm 2.x defaults to the [Responses API](https://platform.openai.com/docs/api-reference/responses)** (`POST /v1/responses`), so updating the gem moves your OpenAI requests to a different endpoint. ActiveAgent leaves that default alone.

A server that speaks only Chat Completions may not implement `/v1/responses`. That includes OpenAI-compatible servers you reach through `openai_api_base`. Set `protocol:` to keep an agent on Chat Completions; it maps to RubyLLM's own `protocol:` option:

```ruby
class ProxiedAgent < ApplicationAgent
  generate_with :ruby_llm, model: "gpt-4o-mini", protocol: :chat_completions
end
```

Or in `config/active_agent.yml`:

```yaml
production:
  ruby_llm:
    service: "RubyLLM"
    model: "gpt-4o-mini"
    protocol: "chat_completions"
```

To change it for every agent, set it on RubyLLM instead: `config.openai_protocol = :chat_completions` in `RubyLLM.configure`. A `protocol:` on an agent wins over that setting.

Valid values are the protocol names of the RubyLLM provider that serves the model. For OpenAI those are `:responses` and `:chat_completions`; a name the provider doesn't have raises RubyLLM's error, which lists the ones it does. The option applies to prompts, not embeddings. It needs ruby_llm 2.x, because 1.16 has no other protocol to choose: with 1.16 installed the provider raises `ArgumentError` instead of ignoring it.

## Provider-Specific Parameters

### Required Parameters

- **`model`** - Model identifier (e.g., "gpt-4o-mini", "claude-sonnet-5")

### Routing Parameters

- **`platform`** - Pins which RubyLLM provider serves the model (maps to RubyLLM's `provider:`), e.g. `:vertexai` for Gemini models on Vertex AI. See [Pinning the Platform](#pinning-the-platform)
- **`protocol`** - Pins which wire protocol carries the request (maps to RubyLLM's `protocol:`), e.g. `:chat_completions` for OpenAI. Needs ruby_llm 2.x. See [Choosing the OpenAI Protocol](#choosing-the-openai-protocol)

### Sampling Parameters

- **`temperature`** - Controls randomness (0.0 to 1.0)
- **`max_tokens`** - Maximum number of tokens to generate (sent as RubyLLM's `max_output_tokens:` on ruby_llm 2.x, and merged into the request through `params:` on 1.16)

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

## Structured Output

The provider passes a `json_schema` response format to RubyLLM (see [Structured Output](/actions/structured_output)). Like RubyLLM's own `with_schema`, it makes the schema **strict unless the format sets `strict: false`**, and names it `response` when the format gives no `name`.

This differs from the OpenAI provider, which leaves `strict` unset, so OpenAI treats the schema as non-strict. A schema that works under `generate_with :openai` can therefore be rejected under `generate_with :ruby_llm`: for example, one with optional properties, or an object without `additionalProperties: false`. Add `strict: false` to the format's `json_schema`, or make the schema meet strict mode's rules.

`json_object` is not supported, because RubyLLM has no JSON object mode; the provider raises `ArgumentError` for it.

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

## Usage and Stop Reasons

`response.usage` reports the tokens RubyLLM counted: `input_tokens` and `output_tokens`, plus `cached_tokens` (read from the prompt cache), `cache_creation_tokens` (written to it) and `reasoning_tokens` when the provider reports them. RubyLLM counts cached tokens apart from the input, so `input_tokens` leaves them out. `usage` is `nil` when the provider reported no counts.

`response.finish_reason` says why the model stopped: `end_turn`, `tool_use` (also for a response that calls tools, whatever the API calls its ending), `max_tokens` for a response cut off at the token limit, or `content_filter`. A reason ActiveAgent has no name for is passed through as the provider spelled it, such as Anthropic's `pause_turn`. Only ruby_llm 2.x reports why a response ended. With 1.16, `finish_reason` is `tool_use` when the model called a tool and `end_turn` otherwise, even for a response cut off at `max_tokens`.

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
- [Dashboard for RubyLLM Apps](/framework/ruby_llm_dashboard) - Telemetry dashboard for an app that stays on RubyLLM directly
- [RubyLLM Documentation](https://rubyllm.com) - Official RubyLLM docs
