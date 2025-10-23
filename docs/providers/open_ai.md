# OpenAI Provider

The OpenAI provider uses the **Responses API** by default, which offers unique capabilities including built-in tools for web search, image generation, and MCP (Model Context Protocol) integration. It also supports vision analysis with GPT-4o and structured outputs with strict schema validation.

::: tip Responses API vs Chat Completions API
The provider uses the **Responses API** by default for access to OpenAI-specific built-in tools. To use the Chat Completions API instead, set `api_version: :chat` in your agent configuration.
:::

## Configuration

### Basic Setup

Configure OpenAI in your agent:

<<< @/../test/dummy/app/agents/providers/open_ai_agent.rb#agent{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/openai_provider_test.rb#openai_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/openai-provider-test.rb-test-basic-generation-with-OpenAI-GPT.md -->
:::

### Configuration File

Set up OpenAI credentials in `config/active_agent.yml`:

::: code-group

<<< @/../test/dummy/config/active_agent.yml#openai_anchor{yaml:line-numbers}

<<< @/../test/dummy/config/active_agent.yml#openai_dev_config{yaml:line-numbers}

:::

### Environment Variables

Alternatively, use environment variables:

```bash
OPENAI_ACCESS_TOKEN=your-api-key
OPENAI_ORGANIZATION_ID=your-org-id  # Optional
```

## Supported Models

OpenAI provides two distinct APIs with different model sets and capabilities.

For the complete list of available models, see [OpenAI's Models Documentation](https://platform.openai.com/docs/models).

### Responses API Models (Recommended)

The Responses API provides access to built-in tools and advanced features:

- **GPT-5** - Advanced model with support for all built-in tools
- **GPT-4.1** - Enhanced GPT-4 with tool support
- **GPT-4.1-mini** - Efficient version with tool support
- **o3** - Reasoning model with advanced capabilities
- **o4-mini** - Compact reasoning model

::: tip
Use the Responses API for access to OpenAI-specific built-in tools like web search, image generation, and MCP integration.
:::

### Chat Completions API Models

Standard chat models compatible with most providers:

- **GPT-4o** - Most capable model with vision capabilities
- **GPT-4o-mini** - Smaller, faster version of GPT-4o
- **GPT-4o-search-preview** - GPT-4o with built-in web search
- **GPT-4o-mini-search-preview** - GPT-4o-mini with built-in web search
- **GPT-4 Turbo** - Latest GPT-4 with 128k context
- **GPT-4** - Original GPT-4 model
- **GPT-3.5 Turbo** - Fast and cost-effective

Note: Search-preview models in Chat API provide web search but with different configuration than Responses API built-in tools.

## Responses API Features

OpenAI's Responses API (the default) provides unique capabilities not available in other providers or the Chat Completions API.

::: tip Using Responses API
The Responses API is used by default. Built-in tools work with compatible Responses API models (GPT-5, GPT-4.1, o3, etc.). To switch to Chat Completions API, set `api_version: :chat`.
:::

### Built-in Tools

The key differentiator of OpenAI's Responses API is access to powerful built-in tools:

#### Web Search

Enable web search capabilities using the `web_search_preview` tool:

<<< @/../test/dummy/app/agents/web_search_agent.rb#17-36{ruby:line-numbers}

#### Image Generation

Generate and edit images using the `image_generation` tool:

<<< @/../test/dummy/app/agents/multimodal_agent.rb#6-26{ruby:line-numbers}

#### MCP (Model Context Protocol) Integration

Connect to external services and MCP servers:

<<< @/../test/dummy/app/agents/mcp_integration_agent.rb#6-29{ruby:line-numbers}

Connect to custom MCP servers:

<<< @/../test/dummy/app/agents/mcp_integration_agent.rb#31-50{ruby:line-numbers}

Available MCP Connectors:
- **Dropbox** - `connector_dropbox`
- **Gmail** - `connector_gmail`
- **Google Calendar** - `connector_googlecalendar`
- **Google Drive** - `connector_googledrive`
- **Microsoft Teams** - `connector_microsoftteams`
- **Outlook Calendar** - `connector_outlookcalendar`
- **Outlook Email** - `connector_outlookemail`
- **SharePoint** - `connector_sharepoint`
- **GitHub** - Use server URL: `https://api.githubcopilot.com/mcp/`

#### Tool Configuration Example

Here's how built-in tools are configured in the prompt options:

<<< @/../test/docs/builtin_tools_doc_test.rb#tool_configuration_example{ruby:line-numbers}

::: details Configuration Output
<!-- @include: @/parts/examples/builtin-tools-doc-test.rb-test-tool-configuration-in-prompt-options.md -->
:::

### Vision Capabilities

GPT-4o and GPT-4o-mini models support image analysis. Provide image URLs or base64-encoded images in your prompts.

**Supported models:**
- GPT-4o (Chat API)
- GPT-4o-mini (Chat API)

**Usage:** Pass image data through the `prompt` method. The provider will automatically handle image content for vision-enabled models.

### Structured Output

OpenAI provides native structured output support with strict schema validation, available in both Chat and Responses APIs.

**Key OpenAI-Specific Features:**
- **Strict Mode** - Guarantees output format conformance with `strict: true`
- **Native JSON Schema Support** - Built into the API, not just prompt engineering
- **Model-Level Validation** - The model enforces the schema during generation

**Configuration:**

Enable structured output with the `response_format` option:

```ruby
class DataExtractionAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",
    response_format: { type: "json_object" }
end
```

For comprehensive documentation on using structured outputs, including schema generation, validation, and examples, see the [Structured Output guide](/agents/structured-output).

### Embeddings

Generate high-quality text embeddings using OpenAI's embedding models. See the [Embeddings Framework Documentation](/framework/embeddings) for comprehensive coverage.

#### Basic Embedding Generation

<<< @/../test/docs/embedding_agent_test.rb#embedding_openai_model_config{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-uses-configured-OpenAI-embedding-model.md -->
:::

#### Available Embedding Models

- **text-embedding-3-large** - Highest quality (3072 dimensions, configurable down to 256)
- **text-embedding-3-small** - Balanced performance (1536 dimensions, configurable)
- **text-embedding-ada-002** - Legacy model (1536 dimensions, fixed)

For detailed model comparisons and benchmarks, see [OpenAI's Embeddings Documentation](https://platform.openai.com/docs/guides/embeddings).

#### Similarity Search Example

<<< @/../test/docs/embedding_agent_test.rb#embedding_similarity_search{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-performs-similarity-search-with-embeddings.md -->
:::

For more advanced embedding patterns, see the [Embeddings Documentation](/framework/embeddings).

#### Dimension Configuration

OpenAI's text-embedding-3 models support configurable dimensions:

<<< @/../test/docs/embedding_agent_test.rb#embedding_dimension_test{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-verifies-embedding-dimensions-for-different-models.md -->
:::

::: tip Dimension Reduction
OpenAI's text-embedding-3-large and text-embedding-3-small models support native dimension reduction by specifying a `dimensions` parameter. This can significantly reduce storage costs while maintaining good performance.
:::

#### Batch Processing

Efficiently process multiple embeddings:

<<< @/../test/docs/embedding_agent_test.rb#embedding_batch_processing{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/embedding-agent-test.rb-test-processes-multiple-embeddings-in-batch.md -->
:::

#### Cost Optimization for Embeddings

Choose the right model based on your needs:

| Model | Dimensions | Cost per 1M tokens | Best for |
|-------|------------|-------------------|----------|
| text-embedding-3-large | 3072 (configurable) | $0.13 | Highest quality, semantic search |
| text-embedding-3-small | 1536 (configurable) | $0.02 | Good balance, most applications |
| text-embedding-ada-002 | 1536 | $0.10 | Legacy support |

::: tip Cost Savings
- Use text-embedding-3-small for most applications (85% cheaper than large)
- Cache embeddings aggressively - they don't change for the same input
- Consider dimension reduction for large-scale applications
:::

## Provider-Specific Parameters

### Model Parameters

- **`model`** - Model identifier (e.g., "gpt-4o", "gpt-3.5-turbo")
- **`embedding_model`** - Embedding model (e.g., "text-embedding-3-large")
- **`dimensions`** - Reduced dimensions for embeddings (for 3-large and 3-small models)
- **`temperature`** - Controls randomness (0.0 to 2.0)
- **`max_tokens`** - Maximum tokens in response
- **`top_p`** - Nucleus sampling parameter
- **`frequency_penalty`** - Penalize frequent tokens (-2.0 to 2.0)
- **`presence_penalty`** - Penalize new topics (-2.0 to 2.0)
- **`seed`** - For deterministic outputs
- **`response_format`** - Output format ({ type: "json_object" } or { type: "text" })

### Organization Settings

- **`organization_id`** - OpenAI organization ID
- **`project_id`** - OpenAI project ID for usage tracking

### Advanced Options

- **`stream`** - Enable streaming responses (true/false)
- **`tools`** - Array of built-in tools for Responses API (web_search_preview, image_generation, mcp)
- **`tool_choice`** - Control tool usage ("auto", "required", "none", or specific tool)
- **`parallel_tool_calls`** - Allow parallel tool execution (true/false)
- **`api_version`** - API version to use (`:responses` [default] or `:chat`)
- **`web_search`** - Web search configuration for Chat API with search-preview models
- **`web_search_options`** - Alternative parameter name for web search in Chat API

## Azure OpenAI

For Azure OpenAI Service, configure a custom host:

```ruby
class AzureAgent < ApplicationAgent
  generate_with :openai,
    access_token: Rails.application.credentials.dig(:azure, :api_key),
    host: "https://your-resource.openai.azure.com",
    api_version: "2024-02-01",
    model: "your-deployment-name"
end
```

## Error Handling

Handle OpenAI-specific errors:

```ruby
class RobustAgent < ApplicationAgent
  generate_with :openai,
    max_retries: 3,
    request_timeout: 30

  rescue_from OpenAI::RateLimitError do |error|
    Rails.logger.error "Rate limit hit: #{error.message}"
    retry_with_backoff
  end

  rescue_from OpenAI::APIError do |error|
    Rails.logger.error "OpenAI API error: #{error.message}"
    fallback_response
  end
end
```

## Related Documentation

- [Providers Overview](/framework/providers)
- [Configuration Guide](/getting-started#configuration)
- [OpenAI API Documentation](https://platform.openai.com/docs)
