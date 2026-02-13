---
title: OpenAI Provider
description: Integration with GPT models including GPT-5, GPT-4.1, GPT-4o, and o3. Responses API with built-in tools or traditional Chat Completions API for standard interactions.
---
# {{ $frontmatter.title }}

The OpenAI provider enables integration with GPT models including GPT-5, GPT-4.1, GPT-4o, o3, and the GPT-4 family. It offers two distinct APIs: the **Responses API** (default) with built-in tools for web search, image generation, and MCP integration, and the traditional **Chat Completions API** for standard chat interactions.

::: tip Responses API vs Chat Completions API
The provider uses the **Responses API** by default for access to OpenAI-specific built-in tools. To use the Chat Completions API instead, set `api_version: :chat` in your agent configuration.

**Responses API (default):**

<<< @/../test/docs/providers/open_ai_examples_test.rb#responses_api_agent{ruby:line-numbers}

**Chat Completions API:**

<<< @/../test/docs/providers/open_ai_examples_test.rb#chat_api_agent{ruby:line-numbers}
:::

## Configuration

### Basic Setup

Configure OpenAI in your agent:

<<< @/../test/docs/providers/open_ai_examples_test.rb#basic_configuration{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/open_ai_examples_test.rb#basic_usage{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/openai-provider-test.rb-test-basic-generation-with-OpenAI-GPT.md -->
:::

### Configuration File

Set up OpenAI credentials in `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml#openai_anchor{yaml:line-numbers}

### Environment Variables

Alternatively, use environment variables:

```bash
OPENAI_ACCESS_TOKEN=your-api-key
OPENAI_ORGANIZATION_ID=your-org-id  # Optional
```

## Supported Models

OpenAI provides two distinct APIs with different model sets and capabilities. For the complete list of available models, see [OpenAI's Models Documentation](https://platform.openai.com/docs/models).

### Responses API Models (Recommended)

The Responses API provides access to built-in tools and advanced features. These models support web search, image generation, and MCP integration:

| Model | Description | Context Window | Best For |
|-------|-------------|----------------|----------|
| **GPT-5** | Most advanced model with all built-in tools | 128K tokens | Complex reasoning, multi-tool tasks |
| **GPT-4.1** | Enhanced GPT-4 with tool support | 128K tokens | Advanced analysis with tools |
| **GPT-4.1-mini** | Efficient version with tool support | 128K tokens | Fast tool-enabled tasks |
| **o3** | Advanced reasoning model | 200K tokens | Deep reasoning, complex problems |
| **o4-mini** | Compact reasoning model | 128K tokens | Efficient reasoning tasks |

**Recommended model identifiers:**
- **gpt-5** - Best for complex tasks requiring multiple tools
- **gpt-4.1** - Best for advanced reasoning with tool support
- **o3** - Best for specialized reasoning tasks

::: tip
Use the Responses API (default) for access to OpenAI-specific built-in tools like web search, image generation, and MCP integration.
:::

### Chat Completions API Models

Standard chat models compatible with most providers. Use `api_version: :chat` to access these:

| Model | Description | Context Window | Best For |
|-------|-------------|----------------|----------|
| **GPT-4o** | Most capable with vision | 128K tokens | Vision analysis, complex reasoning |
| **GPT-4o-mini** | Fast, cost-effective | 128K tokens | Most applications, embeddings |
| **GPT-4o-search-preview** | GPT-4o with web search | 128K tokens | Research, current information |
| **GPT-4o-mini-search-preview** | Mini with web search | 128K tokens | Fast research tasks |
| **GPT-4 Turbo** | Latest GPT-4 | 128K tokens | Advanced analysis |
| **GPT-4** | Original GPT-4 | 8K tokens | General reasoning |
| **GPT-3.5 Turbo** | Fast and economical | 16K tokens | Simple tasks, high volume |

::: warning
Search-preview models in Chat API provide web search but with different configuration than Responses API built-in tools. For consistent tool usage, prefer the Responses API.
:::

## Provider-Specific Parameters

### Required Parameters

- **`model`** - Model identifier (e.g., "gpt-4o", "gpt-3.5-turbo")

### Sampling Parameters

- **`temperature`** - Controls randomness (0.0 to 2.0, default: 1.0)
- **`max_tokens`** - Maximum tokens in response
- **`top_p`** - Nucleus sampling parameter (0.0 to 1.0)
- **`frequency_penalty`** - Penalize frequent tokens (-2.0 to 2.0)
- **`presence_penalty`** - Penalize new topics (-2.0 to 2.0)
- **`seed`** - For deterministic outputs (integer)

### Response Configuration

- **`response_format`** - Output format ({ type: "json_object" } or { type: "text" })
- **`max_tokens`** - Maximum tokens to generate

### Tools & Functions

- **`tools`** - Array of built-in tools for Responses API
  - `web_search_preview` - Enable web search
  - `image_generation` - Enable DALL-E image generation
  - `mcp` - Enable MCP integration
- **`tool_choice`** - Control tool usage ("auto", "required", "none", or specific tool)
- **`parallel_tool_calls`** - Allow parallel tool execution (boolean)
- **`mcps`** - Array of MCP server configurations (max 20)

### Embeddings

- **`embedding_model`** - Embedding model identifier (e.g., "text-embedding-3-large")
- **`dimensions`** - Reduced dimensions for embeddings (text-embedding-3-* models only)

### API Configuration

- **`api_version`** - API version to use (`:responses` [default] or `:chat`)
- **`organization_id`** - OpenAI organization ID
- **`project_id`** - OpenAI project ID for usage tracking

### Client Configuration

- **`access_token`** - OpenAI API key (also accepts `api_key`)
- **`host`** - Custom API endpoint URL (for Azure OpenAI)
- **`request_timeout`** - Request timeout in seconds (default: 30)
- **`max_retries`** - Maximum retry attempts (default: 3)

### Advanced Options

- **`stream`** - Enable streaming responses (boolean)
- **`web_search`** - Web search configuration for Chat API with search-preview models
- **`web_search_options`** - Alternative parameter name for web search in Chat API

## Built-in Tools

OpenAI's Responses API (the default) provides access to powerful built-in tools that extend the model's capabilities beyond text generation.

::: tip Using Responses API
The Responses API is used by default. Built-in tools work with compatible Responses API models (GPT-5, GPT-4.1, o3, etc.). To switch to Chat Completions API, set `api_version: :chat`.
:::

### Web Search

The Responses API enables web search capabilities using the `web_search_preview` tool for real-time information retrieval:

<<< @/../test/docs/providers/open_ai_examples_test.rb#web_search_agent{ruby:line-numbers}

::: tip Best Practice
Web search is particularly useful for questions requiring current information, recent events, or real-time data that's beyond the model's training cutoff.
:::

### Image Generation

The Responses API can generate and edit images using the `image_generation` tool, powered by DALL-E:

<<< @/../test/docs/providers/open_ai_examples_test.rb#image_generation_agent{ruby:line-numbers}

::: warning
Image generation is only available with Responses API models. Chat Completions API models do not support this built-in tool.
:::

### MCP (Model Context Protocol) Integration

The Responses API supports connecting to external services and MCP servers for extended functionality:

**Built-in Connectors:**

<<< @/../test/docs/providers/open_ai_examples_test.rb#mcp_builtin_connectors{ruby:line-numbers}

**Custom MCP Servers:**

<<< @/../test/docs/providers/open_ai_examples_test.rb#mcp_custom_servers{ruby:line-numbers}

**Available MCP Connectors:**
- **connector_dropbox** - Dropbox file access
- **connector_gmail** - Gmail integration
- **connector_googlecalendar** - Google Calendar
- **connector_googledrive** - Google Drive access
- **connector_microsoftteams** - Microsoft Teams
- **connector_outlookcalendar** - Outlook Calendar
- **connector_outlookemail** - Outlook Email
- **connector_sharepoint** - SharePoint access
- **GitHub MCP** - Use server URL: `https://api.githubcopilot.com/mcp/`

::: tip MCP Best Practices
- Limit to 20 MCP servers maximum per request
- Use built-in connectors for popular services
- Implement proper authentication for custom servers
- Monitor rate limits when using external MCP services
:::

### Tool Configuration Example

Here's how built-in tools are configured in the prompt options:

<<< @/../test/docs/providers/open_ai_examples_test.rb#tool_configuration_example{ruby:line-numbers}

::: details Configuration Output
<!-- @include: @/parts/examples/builtin-tools-doc-test.rb-test-tool-configuration-in-prompt-options.md -->
:::

## Vision Capabilities

GPT-4o and GPT-4o-mini models support image analysis through the Chat Completions API. Provide image URLs or base64-encoded images in your prompts.

**Supported Models:**
- GPT-4o (Chat API)
- GPT-4o-mini (Chat API)

**Agent Configuration:**

<<< @/../test/docs/providers/open_ai_examples_test.rb#vision_agent{ruby:line-numbers}

::: tip
Vision capabilities require passing image data as part of the message content structure. See the [integration tests](https://github.com/quiltt/activeagent/tree/main/test/integration/open_ai) for detailed examples of image analysis.
:::

::: warning API Version Requirement
Vision capabilities are only available with Chat Completions API models (GPT-4o, GPT-4o-mini). Set `api_version: :chat` in your configuration.
:::

## Structured Output

OpenAI provides native structured output support with strict schema validation. For comprehensive documentation, see the [Structured Output guide](/actions/structured_output).

**OpenAI-Specific Features:**
- **Strict Mode** - Guarantees output format conformance with `strict: true`
- **Native JSON Schema Support** - Built into the API, not just prompt engineering
- **Model-Level Validation** - The model enforces the schema during generation

**Basic Example:**

<<< @/../test/docs/providers/open_ai_examples_test.rb#structured_output_agent{ruby:line-numbers}

<<< @/../test/docs/providers/open_ai_examples_test.rb#structured_output_usage{ruby:line-numbers}

::: tip
OpenAI's strict mode ensures the model cannot produce invalid output, making it ideal for applications requiring guaranteed schema conformance.
:::

## Embeddings

Generate high-quality text embeddings using OpenAI's embedding models. For general embedding usage, see the [Embeddings Documentation](/actions/embeddings).

#### Available Embedding Models

| Model | Dimensions | Cost per 1M tokens | Best For |
|-------|------------|-------------------|----------|
| **text-embedding-3-large** | 3072 (configurable) | $0.13 | Highest quality, semantic search |
| **text-embedding-3-small** | 1536 (configurable) | $0.02 | Good balance, most applications |
| **text-embedding-ada-002** | 1536 (fixed) | $0.10 | Legacy support |

For detailed model comparisons and benchmarks, see [OpenAI's Embeddings Documentation](https://platform.openai.com/docs/guides/embeddings).

### Configuration

<<< @/../test/docs/providers/open_ai_examples_test.rb#embedding_configuration{ruby:line-numbers}

<<< @/../test/docs/providers/open_ai_examples_test.rb#embedding_usage{ruby:line-numbers}

### Dimension Reduction

OpenAI's text-embedding-3 models support configurable dimensions for cost optimization:

<<< @/../test/docs/providers/open_ai_examples_test.rb#dimension_reduction{ruby:line-numbers}

::: tip OpenAI-Specific Feature
Dimension reduction (256-3072 for text-embedding-3-large, 256-1536 for text-embedding-3-small) reduces storage costs while maintaining good performance. This feature is unique to OpenAI's text-embedding-3 models.
:::

For similarity search, batch processing, and advanced embedding patterns, see the [Embeddings Documentation](/actions/embeddings).

## Azure OpenAI

ActiveAgent provides a dedicated Azure OpenAI provider with first-class support for Azure-specific authentication, deployment-based endpoints, and API versioning.

See the **[Azure OpenAI Provider](/providers/azure)** documentation for full configuration and usage details.

## Error Handling

OpenAI-specific errors can be handled using standard ActiveAgent error handling patterns:

<<< @/../test/docs/providers/open_ai_examples_test.rb#error_handling{ruby:line-numbers}

**Common OpenAI Error Types:**
- `OpenAI::RateLimitError` - Rate limit exceeded
- `OpenAI::APIError` - General API error
- `OpenAI::TimeoutError` - Request timeout
- `OpenAI::AuthenticationError` - Invalid API key
- `OpenAI::InvalidRequestError` - Malformed request

For comprehensive error handling strategies, retry logic, and best practices, see the [Error Handling Documentation](/agents/error_handling).

## Related Documentation

- [Providers Overview](/providers) - Compare all available providers
- [Getting Started](/getting_started) - Complete setup guide
- [Configuration](/framework/configuration) - Environment-specific settings
- [Tools](/actions/tools) - Function calling and MCP integration
- [Structured Output](/actions/structured_output) - JSON schema validation
- [Messages](/actions/messages) - Work with multimodal content
- [Error Handling](/agents/error_handling) - Retry strategies and error handling
- [Testing](/framework/testing) - Test OpenAI integrations
- [OpenAI API Documentation](https://platform.openai.com/docs) - Official OpenAI docs
