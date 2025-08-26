# OpenAI Provider

The OpenAI provider enables integration with OpenAI's GPT models including GPT-4, GPT-4 Turbo, and GPT-3.5 Turbo. It supports advanced features like function calling, streaming responses, and structured outputs.

## Configuration

### Basic Setup

Configure OpenAI in your agent:

<<< @/../test/dummy/app/agents/open_ai_agent.rb#snippet{ruby:line-numbers}

### Configuration File

Set up OpenAI credentials in `config/active_agent.yml`:

```yaml
development:
  openai:
    access_token: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: gpt-4o
    temperature: 0.7
    max_tokens: 4096
    
production:
  openai:
    access_token: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: gpt-4o
    temperature: 0.3
    max_tokens: 2048
```

### Environment Variables

Alternatively, use environment variables:

```bash
OPENAI_ACCESS_TOKEN=your-api-key
OPENAI_ORGANIZATION_ID=your-org-id  # Optional
```

## Supported Models

### Chat Completions API Models
- **GPT-4o** - Most capable model with vision capabilities
- **GPT-4o-mini** - Smaller, faster version of GPT-4o
- **GPT-4o-search-preview** - GPT-4o with built-in web search
- **GPT-4o-mini-search-preview** - GPT-4o-mini with built-in web search
- **GPT-4 Turbo** - Latest GPT-4 with 128k context
- **GPT-4** - Original GPT-4 model
- **GPT-3.5 Turbo** - Fast and cost-effective

### Responses API Models
- **GPT-5** - Advanced model with support for all built-in tools
- **GPT-4.1** - Enhanced GPT-4 with tool support
- **GPT-4.1-mini** - Efficient version with tool support
- **o3** - Reasoning model with advanced capabilities
- **o4-mini** - Compact reasoning model

Note: Built-in tools like MCP and image generation require the Responses API and compatible models.

## Features

### Function Calling

OpenAI supports native function calling with automatic tool execution:

```ruby
class DataAnalysisAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"
  
  def analyze_data
    @data = params[:data]
    prompt  # Will include all public methods as available tools
  end
  
  def calculate_average(numbers:)
    numbers.sum.to_f / numbers.size
  end
  
  def fetch_external_data(endpoint:)
    # Tool that OpenAI can call
    HTTParty.get(endpoint)
  end
end
```

### Streaming Responses

Enable real-time streaming for better user experience:

```ruby
class StreamingAgent < ApplicationAgent
  generate_with :openai, stream: true
  
  on_message_chunk do |chunk|
    # Handle streaming chunks
    broadcast_to_user(chunk)
  end
  
  def chat
    prompt(message: params[:message])
  end
end
```

### Vision Capabilities

GPT-4o models support image analysis:

```ruby
class VisionAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"
  
  def analyze_image
    @image_url = params[:image_url]
    prompt content_type: :text
  end
end

# In your view (analyze_image.text.erb):
# Analyze this image: <%= @image_url %>
```

### Structured Output

Use JSON mode for structured responses:

```ruby
class StructuredAgent < ApplicationAgent
  generate_with :openai, 
    model: "gpt-4o",
    response_format: { type: "json_object" }
  
  def extract_entities
    @text = params[:text]
    prompt(
      output_schema: :entity_extraction,
      instructions: "Extract entities and return as JSON"
    )
  end
end
```

### Built-in Tools (Responses API)

OpenAI's Responses API provides powerful built-in tools for web search, image generation, and MCP integration:

#### Web Search

Enable web search capabilities using the `web_search_preview` tool:

<<< @/../test/dummy/app/agents/web_search_agent.rb#17-36{ruby:line-numbers}

For Chat Completions API with specific models, use `web_search_options`:

<<< @/../test/dummy/app/agents/web_search_agent.rb#52-72{ruby:line-numbers}

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

#### Combining Multiple Tools

Use multiple built-in tools together:

<<< @/../test/dummy/app/agents/multimodal_agent.rb#28-49{ruby:line-numbers}

### Using Concerns for Shared Tools

Create reusable tool configurations with concerns:

<<< @/../test/dummy/app/agents/concerns/research_tools.rb#1-61{ruby:line-numbers}

Use the concern in your agents:

<<< @/../test/dummy/app/agents/research_agent.rb#1-14{ruby:line-numbers}

### Tool Configuration Example

Here's how built-in tools are configured in the prompt options:

<<< @/../test/agents/builtin_tools_doc_test.rb#tool_configuration_example{ruby:line-numbers}

::: details Configuration Output
<!-- @include: @/parts/examples/builtin-tools-doc-test.rb-test-tool-configuration-in-prompt-options.md -->
:::

## Provider-Specific Parameters

### Model Parameters

- **`model`** - Model identifier (e.g., "gpt-4o", "gpt-3.5-turbo")
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
- **`use_responses_api`** - Force use of Responses API (true/false)
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

## Testing

Use VCR for consistent tests:

<<< @/../test/agents/open_ai_agent_test.rb#4-15{ruby:line-numbers}

## Cost Optimization

### Use Appropriate Models

- Use GPT-3.5 Turbo for simple tasks
- Reserve GPT-4o for complex reasoning
- Consider GPT-4o-mini for a balance

### Optimize Token Usage

```ruby
class EfficientAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-3.5-turbo",
    max_tokens: 500,  # Limit response length
    temperature: 0.3  # More focused responses
  
  def summarize
    @content = params[:content]
    # Truncate input if needed
    @content = @content.truncate(3000) if @content.length > 3000
    prompt
  end
end
```

### Cache Responses

```ruby
class CachedAgent < ApplicationAgent
  generate_with :openai
  
  def answer_faq
    question = params[:question]
    
    Rails.cache.fetch("faq/#{question.parameterize}", expires_in: 1.day) do
      prompt(message: question).generate_now
    end
  end
end
```

## Best Practices

1. **Set appropriate temperature** - Lower for factual tasks, higher for creative
2. **Use system messages effectively** - Provide clear instructions
3. **Implement retry logic** - Handle transient failures
4. **Monitor usage** - Track token consumption and costs
5. **Use the latest models** - They're often more capable and cost-effective
6. **Validate outputs** - Especially for critical applications

## Related Documentation

- [Generation Provider Overview](/docs/framework/generation-provider)
- [Configuration Guide](/docs/getting-started#configuration)
- [OpenAI API Documentation](https://platform.openai.com/docs)