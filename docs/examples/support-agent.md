---
title: Support Agent
---
# {{ $frontmatter.title }}

The Support Agent is a simple example demonstrating core ActiveAgent concepts including tool calling, message context, and multimodal responses. It serves as a reference implementation for building customer support chatbots.

## Overview

The Support Agent demonstrates:
- Basic agent setup with instructions
- Tool calling (action methods as tools)
- Message context and conversation flow
- Multimodal responses (text and images)

## Features

- **Simple Configuration** - Minimal setup with clear instructions
- **Tool Integration** - Agent actions become available as AI tools
- **Message Context** - Access complete conversation history
- **Multimodal Support** - Return images and other content types

## Setup

Generate a support agent:

```bash
rails generate active_agent:agent support get_cat_image
```

## Agent Implementation

```ruby
class SupportAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: "You're a support agent. Your job is to help users with their questions."

  def get_cat_image
    prompt(content_type: "image_url", context_id: params[:context_id]) do |format|
      format.text { render plain: CatImageService.fetch_image_url }
    end
  end
end
```

## Usage Examples

### Basic Prompt

Send a simple message to the agent:

```ruby
prompt = SupportAgent.prompt(message: "Hello, I need help")

puts prompt.message.content
# => "Hello, I need help"

response = prompt.generate_now

puts response.message.content
# => "Hello! I'm here to help you. What can I assist you with today?"
```

### Tool Calling

The agent can call its defined actions as tools:

```ruby
message = "Show me a cat"
prompt = SupportAgent.prompt(message: message)

response = prompt.generate_now

# The agent will call the get_cat_image action
puts response.message.content
# => "Here's a cute cat for you! [image displayed]"
```

### Message Context

Access the complete conversation history:

```ruby
response = SupportAgent.prompt(message: "Show me a cat").generate_now

# Messages include system, user, assistant, and tool messages
puts response.prompt.messages.size
# => 5+ messages

# Group messages by role
system_messages = response.prompt.messages.select { |m| m.role == :system }
user_messages = response.prompt.messages.select { |m| m.role == :user }
assistant_messages = response.prompt.messages.select { |m| m.role == :assistant }
tool_messages = response.prompt.messages.select { |m| m.role == :tool }

# System message contains agent instructions
puts system_messages.first.content
# => "You're a support agent. Your job is to help users with their questions."

# The response message is the last message in the context
puts response.message == response.prompt.messages.last
# => true
```

### Inspecting Tool Messages

Tool messages contain the results of action calls:

```ruby
response = SupportAgent.prompt(message: "Show me a cat").generate_now

tool_messages = response.prompt.messages.select { |m| m.role == :tool }

puts tool_messages.first.content
# => Contains the cat image URL: "https://cataas.com/cat/..."

# Assistant messages with requested_actions indicate tool calls
assistant_with_actions = response.prompt.messages.find do |m|
  m.role == :assistant && m.requested_actions&.any?
end

puts assistant_with_actions.requested_actions.first.name
# => "get_cat_image"
```

## Understanding Message Flow

### Message Roles

ActiveAgent uses different message roles for conversation context:

1. **System** - Agent instructions and configuration
2. **User** - User's input messages
3. **Assistant** - AI-generated responses
4. **Tool** - Results from action/tool calls

### Conversation Example

```ruby
response = SupportAgent.prompt(message: "Show me a cat").generate_now

response.prompt.messages.each do |message|
  puts "#{message.role}: #{message.content[0..50]}..."
end

# Output:
# system: You're a support agent. Your job is to help...
# user: Show me a cat
# assistant: [tool_call: get_cat_image]
# tool: https://cataas.com/cat/...
# assistant: Here's a cute cat for you!
```

## Multimodal Responses

### Returning Images

The `get_cat_image` action demonstrates multimodal responses:

```ruby
def get_cat_image
  prompt(
    content_type: "image_url",  # Specify content type
    context_id: params[:context_id]  # Maintain conversation context
  ) do |format|
    format.text { render plain: CatImageService.fetch_image_url }
  end
end
```

### Custom Content Types

Support different response formats:

```ruby
class SupportAgent < ApplicationAgent
  def fetch_document
    prompt(content_type: "application/pdf") do |format|
      format.text { render plain: document_url }
    end
  end

  def get_json_data
    prompt(content_type: "application/json") do |format|
      format.text { render json: { status: "success", data: fetch_data } }
    end
  end
end
```

## Streaming Responses

Enable streaming for real-time responses:

```ruby
prompt = SupportAgent.prompt(message: "Tell me a long story")

prompt.generate_now do |chunk|
  print chunk  # Stream each chunk as it arrives
end
```

## Adding More Actions

Extend the support agent with additional tools:

```ruby
class SupportAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: "You're a support agent. Your job is to help users."

  # Look up order status
  def check_order_status
    @order_id = params[:order_id]
    order = Order.find_by(id: @order_id)

    prompt do |format|
      format.text do
        render plain: "Order ##{@order_id}: #{order.status}"
      end
    end
  end

  # Search knowledge base
  def search_kb
    @query = params[:query]
    articles = KnowledgeBase.search(@query).limit(5)

    prompt do |format|
      format.text do
        render plain: articles.map(&:title).join("\n")
      end
    end
  end

  # Get cat image
  def get_cat_image
    prompt(content_type: "image_url") do |format|
      format.text { render plain: CatImageService.fetch_image_url }
    end
  end
end
```

## Integration with Rails

### Controller Integration

Use the support agent in a controller:

```ruby
class ChatController < ApplicationController
  def message
    response = SupportAgent.prompt(
      message: params[:message],
      context_id: session[:chat_context_id]
    ).generate_now

    # Save context for multi-turn conversations
    session[:chat_context_id] = response.prompt.id

    render json: {
      message: response.message.content,
      context_id: response.prompt.id
    }
  end
end
```

### WebSocket Integration

Stream responses via WebSocket:

```ruby
class ChatChannel < ApplicationCable::Channel
  def message(data)
    prompt = SupportAgent.prompt(message: data["message"])

    prompt.generate_now do |chunk|
      transmit({ chunk: chunk })
    end
  end
end
```

## Testing

### Test Agent Behavior

```ruby
class SupportAgentTest < ActiveSupport::TestCase
  test "agent responds to greetings" do
    response = SupportAgent.prompt(message: "Hello").generate_now

    assert response.message.content.present?
    assert_match(/hello|hi|greet/i, response.message.content)
  end

  test "agent calls get_cat_image tool" do
    response = SupportAgent.prompt(message: "Show me a cat").generate_now

    # Check that tool was called
    tool_messages = response.prompt.messages.select { |m| m.role == :tool }
    assert tool_messages.any?

    # Check that response mentions the cat
    assert response.message.content.present?
  end
end
```

### Mock Tool Responses

Mock external services in tests:

```ruby
class SupportAgentTest < ActiveSupport::TestCase
  setup do
    CatImageService.stub :fetch_image_url, "https://example.com/cat.jpg" do
      @response = SupportAgent.prompt(message: "Show me a cat").generate_now
    end
  end

  test "returns mocked cat image" do
    tool_messages = @response.prompt.messages.select { |m| m.role == :tool }
    assert_includes tool_messages.first.content, "example.com/cat.jpg"
  end
end
```

## Configuration Options

### Model Selection

Choose appropriate models for your use case:

```ruby
class SupportAgent < ApplicationAgent
  # Fast and economical for simple support
  generate_with :openai, model: "gpt-4o-mini"

  # More capable for complex queries
  # generate_with :openai, model: "gpt-4o"

  # Maximum capability for advanced support
  # generate_with :openai, model: "gpt-5"
end
```

### Custom Instructions

Tailor agent behavior with specific instructions:

```ruby
class SupportAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: <<~INSTRUCTIONS
      You're a technical support agent for Acme Corp.

      Guidelines:
      - Always be polite and professional
      - Ask clarifying questions when needed
      - Provide step-by-step solutions
      - Escalate to human support for billing issues

      Available tools:
      - check_order_status: Look up order information
      - search_kb: Search knowledge base
      - get_cat_image: Send a cat image (for fun)
    INSTRUCTIONS
end
```

## Best Practices

### Context Management

Maintain conversation context across turns:

```ruby
# First message
response1 = SupportAgent.prompt(
  message: "I have a problem",
  context_id: user_session_id
).generate_now

# Follow-up message uses same context
response2 = SupportAgent.prompt(
  message: "Can you explain more?",
  context_id: user_session_id
).generate_now

# Both responses share the same conversation history
```

### Error Handling

Handle errors gracefully:

```ruby
def check_order_status
  @order_id = params[:order_id]
  order = Order.find_by(id: @order_id)

  prompt do |format|
    format.text do
      if order
        render plain: "Order ##{@order_id}: #{order.status}"
      else
        render plain: "Order not found. Please check the order number."
      end
    end
  end
rescue => e
  prompt do |format|
    format.text do
      render plain: "Error checking order: #{e.message}"
    end
  end
end
```

### Rate Limiting

Implement rate limiting for production:

```ruby
class SupportAgent < ApplicationAgent
  before_action :check_rate_limit

  private

  def check_rate_limit
    user_id = params[:user_id]
    key = "support_agent:#{user_id}"
    count = Rails.cache.increment(key, 1, expires_in: 1.minute)

    if count > 10
      raise "Rate limit exceeded. Please try again later."
    end
  end
end
```

## Conclusion

The Support Agent provides a simple, clear example of core ActiveAgent concepts. It demonstrates how to build conversational AI agents with tool calling, message context, and multimodal responses—all while maintaining familiar Rails patterns and conventions.
