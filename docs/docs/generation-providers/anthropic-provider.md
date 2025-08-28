# Anthropic Provider

The Anthropic provider enables integration with Claude models including Claude 3.5 Sonnet, Claude 3 Opus, and Claude 3 Haiku. It offers advanced reasoning capabilities, extended context windows, and strong performance on complex tasks.

## Configuration

### Basic Setup

Configure Anthropic in your agent:

<<< @/../test/dummy/app/agents/anthropic_agent.rb{ruby:line-numbers}

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
ANTHROPIC_VERSION=2023-06-01  # Optional API version
```

## Supported Models

### Claude 3.5 Family
- **claude-3-5-sonnet-latest** - Most intelligent model with best performance
- **claude-3-5-sonnet-20241022** - Specific version for reproducibility

### Claude 3 Family
- **claude-3-opus-latest** - Most capable Claude 3 model
- **claude-3-sonnet-20240229** - Balanced performance and cost
- **claude-3-haiku-20240307** - Fastest and most cost-effective

## Features

### Extended Context Window

Claude models support up to 200K tokens of context:

```ruby
class DocumentAnalyzer < ApplicationAgent
  generate_with :anthropic, 
    model: "claude-3-5-sonnet-latest",
    max_tokens: 4096
  
  def analyze_document
    @document = params[:document]  # Can be very long
    prompt instructions: "Analyze this document thoroughly"
  end
end
```

### System Messages

Anthropic models excel at following system instructions:

```ruby
class SpecializedAgent < ApplicationAgent
  generate_with :anthropic,
    model: "claude-3-5-sonnet-latest",
    system: "You are an expert Ruby developer specializing in Rails applications."
  
  def review_code
    @code = params[:code]
    prompt
  end
end
```

### Tool Use

Claude supports function calling through tool use:

```ruby
class ToolAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-5-sonnet-latest"
  
  def process_request
    @request = params[:request]
    prompt  # Includes all public methods as tools
  end
  
  def search_database(query:, table:)
    # Tool that Claude can call
    ActiveRecord::Base.connection.execute(
      "SELECT * FROM #{table} WHERE #{query}"
    )
  end
  
  def calculate(expression:)
    # Another available tool
    eval(expression)  # In production, use a safe math parser
  end
end
```

### Streaming Responses

Enable streaming for real-time output:

```ruby
class StreamingClaudeAgent < ApplicationAgent
  generate_with :anthropic, 
    model: "claude-3-5-sonnet-latest",
    stream: true
  
  on_message_chunk do |chunk|
    # Handle streaming chunks
    ActionCable.server.broadcast("chat_#{params[:session_id]}", chunk)
  end
  
  def chat
    prompt(message: params[:message])
  end
end
```

### Structured Output

While Anthropic doesn't provide native structured output like OpenAI's JSON mode, Claude models excel at following JSON format instructions and producing well-structured outputs.

#### Approach

Claude's strong instruction-following capabilities make it reliable for JSON generation:

```ruby
class AnthropicStructuredAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-5-sonnet-latest"
  
  def extract_data
    @text = params[:text]
    @schema = params[:schema]
    
    prompt(
      instructions: build_json_instructions,
      message: @text
    )
  end
  
  private
  
  def build_json_instructions
    <<~INSTRUCTIONS
      You must respond with valid JSON that conforms to this schema:
      #{@schema.to_json}
      
      Ensure your response:
      - Is valid JSON without any markdown formatting
      - Includes all required fields
      - Uses the exact property names from the schema
      - Contains appropriate data types for each field
    INSTRUCTIONS
  end
end
```

#### With Schema Generator

Use ActiveAgent's schema generator with Claude:

```ruby
# Define your model
class ExtractedData
  include ActiveModel::Model
  include ActiveAgent::SchemaGenerator
  
  attribute :name, :string
  attribute :email, :string
  attribute :age, :integer
  
  validates :name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
end

# Generate and use the schema
schema = ExtractedData.to_json_schema
response = AnthropicAgent.with(
  text: "John Doe, 30 years old, john@example.com",
  schema: schema
).extract_data.generate_now

# Parse the JSON response
data = JSON.parse(response.message.content)
```

#### Best Practices for Structured Output with Claude

1. **Clear Instructions**: Provide explicit JSON formatting instructions in the system message
2. **Schema in Prompt**: Include the schema definition directly in the prompt
3. **Example Output**: Consider providing an example of the expected JSON format
4. **Validation**: Always validate the returned JSON against your schema
5. **Error Handling**: Implement fallback logic for malformed responses

#### Example with Validation

```ruby
class ValidatedAnthropicAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-5-sonnet-latest"
  
  def extract_with_validation
    response = prompt(
      instructions: json_instructions,
      message: params[:text]
    )
    
    # Validate and parse response
    begin
      json_data = JSON.parse(response.message.content)
      validate_against_schema(json_data)
      json_data
    rescue JSON::ParserError => e
      handle_invalid_json(e)
    end
  end
  
  private
  
  def validate_against_schema(data)
    # Implement schema validation logic
    JSON::Validator.validate!(schema, data)
  end
end
```

#### Advantages with Claude

- **Reliability**: Claude consistently follows formatting instructions
- **Flexibility**: Can handle complex nested schemas
- **Context**: Excellent at understanding context for accurate extraction
- **Reasoning**: Can explain extraction decisions when needed

See the [Structured Output guide](/docs/active-agent/structured-output) for more examples and patterns.

### Vision Capabilities

Claude models support image analysis:

```ruby
class VisionAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-5-sonnet-latest"
  
  def analyze_image
    @image_path = params[:image_path]
    @image_base64 = Base64.encode64(File.read(@image_path))
    
    prompt content_type: :text
  end
end

# In your view (analyze_image.text.erb):
# Analyze this image: [base64 image data would be included]
```

## Provider-Specific Parameters

### Model Parameters

- **`model`** - Model identifier (e.g., "claude-3-5-sonnet-latest")
- **`max_tokens`** - Maximum tokens to generate (required)
- **`temperature`** - Controls randomness (0.0 to 1.0)
- **`top_p`** - Nucleus sampling parameter
- **`top_k`** - Top-k sampling parameter
- **`stop_sequences`** - Array of sequences to stop generation

### Metadata

- **`metadata`** - Custom metadata for request tracking
  ```ruby
  generate_with :anthropic,
    metadata: {
      user_id: -> { Current.user&.id },
      request_id: -> { SecureRandom.uuid }
    }
  ```

### Safety Settings

- **`anthropic_version`** - API version for consistent behavior
- **`anthropic_beta`** - Enable beta features

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

## Testing

Example test setup with Anthropic:

```ruby
class AnthropicAgentTest < ActiveSupport::TestCase
  test "generates response with Claude" do
    VCR.use_cassette("anthropic_claude_response") do
      response = AnthropicAgent.with(
        message: "Explain Ruby blocks"
      ).prompt_context.generate_now
      
      assert_not_nil response.message.content
      assert response.message.content.include?("block")
      
      doc_example_output(response)
    end
  end
end
```

## Cost Optimization

### Model Selection

- Use Claude 3 Haiku for simple tasks
- Use Claude 3.5 Sonnet for complex reasoning
- Reserve Claude 3 Opus for the most demanding tasks

### Token Management

```ruby
class EfficientClaudeAgent < ApplicationAgent
  generate_with :anthropic,
    model: "claude-3-haiku-20240307",
    max_tokens: 500  # Limit output length
  
  def quick_summary
    @content = params[:content]
    
    # Truncate input if needed
    if @content.length > 10_000
      @content = @content.truncate(10_000, omission: "... [truncated]")
    end
    
    prompt instructions: "Provide a brief summary"
  end
end
```

### Response Caching

```ruby
class CachedClaudeAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-3-5-sonnet-latest"
  
  def answer_question
    question = params[:question]
    
    cache_key = "claude_answer/#{Digest::SHA256.hexdigest(question)}"
    
    Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      prompt(message: question).generate_now
    end
  end
end
```

## Best Practices

1. **Always specify max_tokens** - Required parameter for Anthropic
2. **Use appropriate models** - Balance cost and capability
3. **Leverage system messages** - Claude follows them very well
4. **Handle rate limits gracefully** - Implement exponential backoff
5. **Monitor token usage** - Track costs and optimize
6. **Use caching strategically** - Reduce API calls for repeated queries
7. **Validate outputs** - Especially for critical applications

## Anthropic-Specific Considerations

### Constitutional AI

Claude is trained with Constitutional AI, making it particularly good at:
- Following ethical guidelines
- Refusing harmful requests
- Providing balanced perspectives
- Being helpful, harmless, and honest

### Context Window Management

```ruby
class LongContextAgent < ApplicationAgent
  generate_with :anthropic,
    model: "claude-3-5-sonnet-latest",
    max_tokens: 4096
  
  def analyze_codebase
    # Claude can handle very large contexts effectively
    @files = load_all_project_files  # Up to 200K tokens
    
    prompt instructions: "Analyze this entire codebase"
  end
  
  private
  
  def load_all_project_files
    Dir.glob("app/**/*.rb").map do |file|
      "// File: #{file}\n#{File.read(file)}"
    end.join("\n\n")
  end
end
```

## Related Documentation

- [Generation Provider Overview](/docs/framework/generation-provider)
- [Configuration Guide](/docs/getting-started#configuration)
- [Anthropic API Documentation](https://docs.anthropic.com/claude/reference)