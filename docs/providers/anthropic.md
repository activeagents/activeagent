---
title: Anthropic Provider
description: Integration with Claude models including Sonnet 4.5, Haiku 4.5, and Opus 4.1. Advanced reasoning, extended context windows, thinking mode, and strong performance on complex tasks.
---
# {{ $frontmatter.title }}

The Anthropic provider enables integration with Claude models including Claude Sonnet 4.5, Claude Haiku 4.5, Claude Opus 4.1, and the Claude 3.x family. It offers advanced reasoning capabilities, extended context windows, extended thinking mode, and strong performance on complex tasks.

## Configuration

### Basic Setup

Configure Anthropic in your agent:

<<< @/../test/dummy/app/agents/providers/anthropic_agent.rb#agent{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/anthropic_examples_test.rb#anthropic_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/anthropic-provider-test.rb-test-basic-generation-with-Anthropic-Claude.md -->
:::

### Configuration File

Set up Anthropic credentials in `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml#anthropic_anchor{yaml:line-numbers}

### Environment Variables

Alternatively, use environment variables:

```bash
ANTHROPIC_API_KEY=your-api-key
```

## Supported Models

Anthropic provides access to the Claude model family. For the complete list of available models, see [Anthropic's Models Overview](https://docs.anthropic.com/en/docs/about-claude/models).

### Claude 4.x Family (Latest)

| Feature | Claude Sonnet 4.5 | Claude Haiku 4.5 | Claude Opus 4.1 |
|---------|-------------------|------------------|-----------------|
| **Description** | Smartest model for complex agents and coding | Fastest model with near-frontier intelligence | Exceptional model for specialized reasoning |
| **Pricing** | $3 / MTok input<br>$15 / MTok output | $1 / MTok input<br>$5 / MTok output | $15 / MTok input<br>$75 / MTok output |
| **Extended Thinking** | ✓ | ✓ | ✓ |
| **Priority Tier** | ✓ | ✓ | ✓ |
| **Latency** | Fast | Fastest | Moderate |
| **Context Window** | 200K tokens<br>1M tokens (beta) | 200K tokens | 200K tokens |
| **Max Output** | 64K tokens | 64K tokens | 32K tokens |
| **Knowledge Cutoff** | Jan 2025 | Feb 2025 | Jan 2025 |
| **Training Data** | Jul 2025 | Jul 2025 | Mar 2025 |

**Recommended model identifiers:**
- **claude-sonnet-4.5** - Best for complex reasoning and coding tasks
- **claude-haiku-4.5** - Best for speed with high intelligence
- **claude-opus-4.1** - Best for specialized reasoning tasks requiring deep analysis

### Claude 3.5 Family
- **claude-3-5-sonnet-latest** - Most intelligent Claude 3.5 model
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
- **`mcps`** - Array of MCP server definitions (max 20)

### Client Configuration

- **`api_key`** - Anthropic API key (also accepts `access_token`)
- **`base_url`** - API endpoint URL (default: "https://api.anthropic.com")
- **`timeout`** - Request timeout in seconds (default: 600.0)
- **`max_retries`** - Maximum retry attempts (default: 2)
- **`anthropic_beta`** - Enable beta features via header

### Response Format

- **`response_format`** - Control output format (see [Emulated JSON Object Support](#emulated-json-object-support))

### Streaming

- **`stream`** - Enable streaming responses (boolean, default: false)

## Emulated JSON Object Support

While Anthropic does not natively support structured response formats like OpenAI's `json_object` mode, ActiveAgent provides emulated support through a prompt engineering technique.

When you specify `response_format: { type: "json_object" }`, the framework:

1. **Adds a lead-in assistant message** containing `"Here is the JSON requested:\n{"` to prime Claude to output JSON
2. **Receives Claude's response** which continues from the opening brace
3. **Reconstructs the complete JSON** by prepending the `{` character
4. **Removes the lead-in message** from the message stack for clean conversation history

### Usage Example

<<< @/../test/docs/providers/anthropic_examples_test.rb#response_format_json_object_agent{ruby:line-numbers} [agent]

<<< @/../test/docs/providers/anthropic_examples_test.rb#response_format_json_object_example{ruby:line-numbers} [usage]

### Best Practices

- **Be explicit in your prompt**: Ask Claude to "return a JSON object" or "respond with valid JSON"
- **Specify the schema**: Describe the expected structure in your prompt for better results
- **Validate the output**: While Claude is reliable, always validate parsed JSON in production

### Limitations

Unlike OpenAI's native JSON mode:
- **No schema enforcement**: Claude is not forced to conform to a specific schema
- **Prompt-dependent reliability**: Success depends on clear prompt instructions
- **No strict mode**: Cannot guarantee specific field requirements

For applications requiring guaranteed schema conformance, consider using the [Structured Output](/actions/structured_output) feature with providers that support native JSON schema validation.

## Constitutional AI

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

- [Providers Overview](/providers) - Compare all available providers
- [Getting Started](/getting_started) - Complete setup guide
- [Configuration](/framework/configuration) - Environment-specific settings
- [Tools](/actions/tools) - Function calling and MCP integration
- [Messages](/actions/messages) - Work with multimodal content
- [Structured Output](/actions/structured_output) - JSON response formatting
- [Error Handling](/agents/error_handling) - Retry strategies and error handling
- [Testing](/framework/testing) - Test Anthropic integrations
- [Anthropic API Documentation](https://docs.anthropic.com/en/api) - Official Anthropic docs
