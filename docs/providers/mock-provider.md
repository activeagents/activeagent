# Mock Provider

The Mock provider is designed for testing purposes, allowing you to develop and test agents without making actual API calls or incurring costs. It returns predictable responses by converting input text to pig latin and generates random embeddings.

## Configuration

### Basic Setup

Configure the Mock provider in your agent:

<<< @/../test/dummy/app/agents/providers/mock_agent.rb{ruby:line-numbers}

### Configuration File

The Mock provider doesn't require API keys or credentials:

```yaml
# config/active_agent.yml
development:
  mock:
    service: "Mock"
    model: "mock-model"  # Optional, any value works

test:
  mock:
    service: "Mock"
```

### Environment Variables

No environment variables are required for the Mock provider.

## Use Cases

### Testing Without API Costs

Develop and test your agent logic without calling external APIs:

```ruby
class TestableAgent < ApplicationAgent
  generate_with :mock

  def process_request
    @request = params[:request]
    prompt(message: @request)
  end
end

# In your tests
response = TestableAgent.with(request: "Hello world").process_request.generate_now
assert_not_nil response.message.content
# Returns: "Ellohay orldway" (pig latin conversion)
```

### Offline Development

Work on your application without network connectivity:

```ruby
class OfflineAgent < ApplicationAgent
  generate_with :mock,
    instructions: "You are a helpful assistant."

  def chat
    prompt(message: params[:message])
  end
end
```

### Integration Testing

Test agent behavior and message flow without external dependencies:

```ruby
class IntegrationTest < ActiveSupport::TestCase
  test "agent processes messages correctly" do
    response = Providers::MockAgent.with(message: "Test input").ask.generate_now

    assert response.success?
    assert_not_nil response.message.content
    assert_equal "assistant", response.message.role
  end
end
```

## Features

### Pig Latin Responses

The Mock provider converts user messages to pig latin for predictable output:

```ruby
agent = Providers::MockAgent.with(message: "Hello world")
response = agent.ask.generate_now

# Input: "Hello world"
# Output: "Ellohay orldway"
```

**Conversion Rules:**
- Words starting with vowels: add "way" to the end ("apple" → "appleway")
- Words starting with consonants: move consonants to end and add "ay" ("hello" → "ellohay")
- Preserves punctuation and capitalization

### Streaming Responses

Test streaming functionality without real API calls:

```ruby
class StreamingMockAgent < ApplicationAgent
  generate_with :mock, stream: true

  on_message_chunk do |chunk|
    # Handle streaming chunks
    puts "Chunk received: #{chunk}"
  end

  def chat
    prompt(message: params[:message])
  end
end

# Simulates streaming by breaking response into chunks
response = StreamingMockAgent.with(message: "Hello").chat.generate_now
```

### Random Embeddings

Generate random embedding vectors for testing embedding functionality:

```ruby
class EmbeddingTest < ActiveSupport::TestCase
  test "generates embeddings" do
    provider = ActiveAgent::Providers::MockProvider.new(
      service: "Mock",
      input: "test text",
      dimensions: 768
    )

    response = provider.embed

    assert_equal 768, response.data.first[:embedding].size
    assert response.data.first[:embedding].all? { |v| v.is_a?(Float) }
  end
end
```

### Response Structure

Mock responses follow the same structure as real providers:

```ruby
response = Providers::MockAgent.with(message: "Test").ask.generate_now

# Response structure
response.message.role      # => "assistant"
response.message.content   # => "Esttay" (pig latin)
response.raw_response      # => Complete mock response hash
response.usage             # => Token usage information
```

## Testing Examples

### Basic Test

```ruby
class MockProviderTest < ActiveSupport::TestCase
  test "mock agent basic generation" do
    response = Providers::MockAgent.with(message: "What is ActiveAgent?").ask.generate_now

    assert response.success?
    assert_not_nil response.message.content
    assert response.message.content.length > 0
  end
end
```

### Testing Message Flow

```ruby
class MessageFlowTest < ActiveSupport::TestCase
  test "processes multiple messages" do
    agent = Providers::MockAgent.new

    response1 = agent.with(message: "First").ask.generate_now
    response2 = agent.with(message: "Second").ask.generate_now

    assert_not_equal response1.message.content, response2.message.content
  end
end
```

### Testing Callbacks

```ruby
class CallbackTest < ActiveSupport::TestCase
  test "triggers callbacks during generation" do
    callback_triggered = false

    class CallbackAgent < ApplicationAgent
      generate_with :mock

      before_generate { callback_triggered = true }

      def process
        prompt(message: params[:message])
      end
    end

    CallbackAgent.with(message: "test").process.generate_now
    assert callback_triggered
  end
end
```

## Limitations

### No Real AI Responses

The Mock provider doesn't use actual AI models, so responses are deterministic transformations (pig latin) rather than intelligent completions.

### No Tool Calling

The Mock provider doesn't support function/tool calling:

```ruby
class ToolAgent < ApplicationAgent
  generate_with :mock

  def process
    prompt(message: params[:message])
  end

  def calculate(numbers:)
    # This tool won't be called by Mock provider
    numbers.sum
  end
end
```

### Limited Structured Output

While the Mock provider accepts structured output parameters, it doesn't validate or enforce schemas:

```ruby
# Schema is accepted but not enforced
response = agent.prompt(
  message: "Extract data",
  output_schema: { type: "object", properties: { name: { type: "string" } } }
).generate_now

# Response will still be pig latin, not structured JSON
```

## Best Practices

### Use for Development

1. **Start with Mock** - Develop agent logic using the Mock provider first
2. **Switch for Testing** - Use real providers for integration tests with VCR
3. **Switch for Production** - Use real providers in production environments

```ruby
class AdaptiveAgent < ApplicationAgent
  generate_with Rails.env.test? ? :mock : :openai,
    model: "gpt-4o-mini"

  def process
    prompt(message: params[:message])
  end
end
```

### Environment-Based Configuration

```ruby
# config/active_agent.yml
development:
  default_provider: mock
  mock:
    service: "Mock"

test:
  default_provider: mock
  mock:
    service: "Mock"

production:
  default_provider: openai
  openai:
    service: "OpenAI"
    access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
```

### Testing Strategy

1. **Unit Tests** - Use Mock provider for fast, isolated tests
2. **Integration Tests** - Use VCR with real providers to capture actual API responses
3. **System Tests** - Use real providers for end-to-end testing

```ruby
class AgentTest < ActiveSupport::TestCase
  # Fast unit test with Mock
  test "agent processes input" do
    response = Providers::MockAgent.with(message: "test").ask.generate_now
    assert response.success?
  end

  # Integration test with VCR
  test "agent with real provider" do
    VCR.use_cassette("openai_response") do
      response = Providers::OpenAIAgent.with(message: "test").ask.generate_now
      assert response.success?
    end
  end
end
```

### Debugging

The Mock provider's predictable responses make debugging easier:

```ruby
class DebugAgent < ApplicationAgent
  generate_with :mock

  after_generate do |response|
    Rails.logger.info "Mock response: #{response.message.content}"
    Rails.logger.info "Input was: #{params[:message]}"
  end

  def process
    prompt(message: params[:message])
  end
end
```

## Implementation Details

### How It Works

The Mock provider:

1. **Extracts** the last user message from the conversation
2. **Converts** the message content to pig latin
3. **Returns** a response structure matching real provider formats
4. **Simulates** streaming by breaking the response into chunks (if streaming enabled)

### Message Extraction

Handles various message formats:

```ruby
# Simple string message
{ role: "user", content: "Hello" }
# => "Ellohay"

# Content blocks
{
  role: "user",
  content: [
    { type: "text", text: "Hello" },
    { type: "text", text: "world" }
  ]
}
# => "Ellohay orldway"
```

### Streaming Simulation

For streaming requests, the Mock provider:

1. Sends a `message_start` event
2. Sends a `content_block_start` event
3. Breaks response into word chunks
4. Sends `content_block_delta` events for each chunk
5. Sends a `message_stop` event

This simulates real streaming behavior for testing streaming handlers.

## Related Documentation

- [Provider Overview](/framework/provider) - Understanding provider architecture
- [Testing Guide](/testing) - Comprehensive testing strategies
- [OpenAI Provider](/providers/openai-provider) - Production-ready provider
- [Anthropic Provider](/providers/anthropic-provider) - Alternative production provider
