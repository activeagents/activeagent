# Anthropic Provider

The Anthropic provider enables integration with Claude models including Claude 3.5 Sonnet, Claude 3 Opus, and Claude 3 Haiku. It offers advanced reasoning capabilities, extended context windows, and strong performance on complex tasks.

## Configuration

### Basic Setup

Configure Anthropic in your agent:

<<< @/../test/dummy/app/agents/providers/anthropic_agent.rb#agent{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/anthropic_provider_test.rb#anthropic_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/anthropic-provider-test.rb-test-basic-generation-with-Anthropic-Claude.md -->
:::

### Configuration File

Set up Anthropic credentials in `config/active_agent.yml`:

::: code-group

<<< @/../test/dummy/config/active_agent.yml#anthropic_anchor{yaml:line-numbers}

<<< @/../test/dummy/config/active_agent.yml#anthropic_dev_config{yaml:line-numbers}

:::

### Environment Variables

Alternatively, use environment variables:

```bash
ANTHROPIC_API_KEY=your-api-key
```

## Supported Models

Anthropic provides access to the Claude model family. For the complete list of available models, see [Anthropic's Models Overview](https://docs.anthropic.com/en/docs/about-claude/models).

### Claude 3.5 Family
- **claude-3-5-sonnet-latest** - Most intelligent model with best performance
- **claude-3-5-sonnet-20241022** - Specific version for reproducibility

### Claude 3 Family
- **claude-3-opus-latest** - Most capable Claude 3 model
- **claude-3-sonnet-20240229** - Balanced performance and cost
- **claude-3-haiku-20240307** - Fastest and most cost-effective

## Provider-Specific Parameters

### Required Parameters

- **`model`** - Model identifier (e.g., "claude-3-5-sonnet-latest")
- **`max_tokens`** - Maximum tokens to generate (default: 4096, minimum: 1)

### Sampling Parameters

- **`temperature`** - Controls randomness (0.0 to 1.0, default: varies by model)
- **`top_p`** - Nucleus sampling parameter (0.0 to 1.0)
- **`top_k`** - Top-k sampling parameter (integer ≥ 0)
- **`stop_sequences`** - Array of strings to stop generation

### System & Instructions

- **`system`** - System message to guide Claude's behavior
- **`instructions`** - Alias for `system` (for common format compatibility)

### Tools & Functions

- **`tools`** - Array of tool definitions for function calling
- **`tool_choice`** - Control which tools can be used ("auto", "any", or specific tool)

### Metadata & Tracking

- **`metadata`** - Custom metadata for request tracking
  ```ruby
  generate_with :anthropic,
    metadata: {
      user_id: -> { Current.user&.id }
    }
  ```

### Advanced Features

- **`thinking`** - Enable Claude's thinking mode for complex reasoning
- **`context_management`** - Configure context window management
- **`service_tier`** - Select service tier ("auto", "standard_only")
- **`mcp_servers`** - Array of MCP server definitions (max 20)

### Client Configuration

- **`api_key`** - Anthropic API key (also accepts `access_token`)
- **`base_url`** - API endpoint URL (default: "https://api.anthropic.com")
- **`timeout`** - Request timeout in seconds (default: 600.0)
- **`max_retries`** - Maximum retry attempts (default: 2)
- **`anthropic_beta`** - Enable beta features via header

### Streaming

- **`stream`** - Enable streaming responses (boolean, default: false)

## Anthropic-Specific Features

### Constitutional AI

Claude is trained with Constitutional AI, making it particularly good at:
- Following ethical guidelines
- Refusing harmful requests
- Providing balanced perspectives
- Being helpful, harmless, and honest

## Error Handling

Handle Anthropic-specific errors:

```ruby
class ResilientAgent < ApplicationAgent
  generate_with :anthropic,
    model: "claude-3-5-sonnet-latest",
    max_retries: 3

  rescue_from Anthropic::RateLimitError do |error|
    Rails.logger.warn "Rate limited: #{error.message}"
    sleep(error.retry_after || 60)
    retry
  end

  rescue_from Anthropic::APIError do |error|
    Rails.logger.error "Anthropic error: #{error.message}"
    fallback_to_cached_response
  end
end
```

## Related Documentation

- [Providers Overview](/framework/providers)
- [Configuration Guide](/getting-started#configuration)
- [Anthropic API Documentation](https://docs.anthropic.com/claude/reference)
