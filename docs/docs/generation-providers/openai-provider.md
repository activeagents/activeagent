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

- **GPT-4o** - Most capable model with vision capabilities
- **GPT-4o-mini** - Smaller, faster version of GPT-4o
- **GPT-4 Turbo** - Latest GPT-4 with 128k context
- **GPT-4** - Original GPT-4 model
- **GPT-3.5 Turbo** - Fast and cost-effective

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
- **`tools`** - Explicitly define available tools
- **`tool_choice`** - Control tool usage ("auto", "required", "none", or specific tool)
- **`parallel_tool_calls`** - Allow parallel tool execution (true/false)

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