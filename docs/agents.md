---
title: Agents
---
# Agents

Controllers for AI interactions. Like Rails controllers, agents have actions, callbacks, views, and concerns—but they generate AI responses instead of rendering HTML.

## Quick Example

```ruby
class SupportAgent < ApplicationAgent
  before_generation :load_user_context

  def help
    prompt # Messages with app/views/agents/support/help.md.erb
  end

  private

  def load_user_context
    @user = User.find(params[:user_id])
  end
end

# Usage
SupportAgent.with(user_id: 123, message: "Need help").help.generate_now
```

## How It Works

The request-response cycle mirrors Rails controllers:

1. **Action called** - `Agent.with(params).action`
2. **Callbacks run** - `before_generation`, `before_prompting`
3. **Context built** - `prompt()` or `embed()` configures messages
4. **View rendered** - ERB template (if exists) renders content
5. **Provider executes** - AI service generates response
6. **Result returned** - Response object with message and metadata

## Building Agents

### Basic Structure

Inherit from `ActiveAgent::Base` (or `ApplicationAgent`) and define actions:

```ruby
class TranslationAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  def translate
    prompt # Messages with app/views/translation_agent/translate.text.erb
  end
end
```

Actions are public instance methods that call `prompt()` or `embed()`.

### Invocation

Call agents using `with()` to pass parameters:

```ruby
# With parameters
generation = TranslationAgent.with(
  text: "Hello world",
  target_lang: "es"
).translate

# Execute synchronously
response = generation.generate_now
response.message.content  # => "Hola mundo"

# Execute asynchronously
generation.generate_later(queue: :agents)
```

For prototyping, use direct methods:

```ruby
MyAgent.prompt(message: "Hello").generate_now
MyAgent.embed(input: "Text").embed_now
```

### Actions Interface

Agents define actions using `prompt()` or `embed()` to configure generation context:

**Prompting**

```ruby
def my_action
  # Simple message
  prompt "User message"
end

def embed_text
  # Simple input
  embed "Text to embed"
end
```

See [Actions](/actions) for complete documentation on messages, tools, structured output, and embeddings.

## Advanced Features

### Using Concerns

Extend agents with concerns to share functionality across multiple agents:

```ruby
# app/agents/concerns/research_tools.rb
module ResearchTools
  extend ActiveSupport::Concern

  def search_papers
    prompt message: "Search: #{params[:query]}"
  end

  def analyze_data
    prompt message: "Analyze: #{params[:data]}"
  end
end

# app/agents/research_agent.rb
class ResearchAgent < ApplicationAgent
  include ResearchTools  # Adds search_papers and analyze_data actions

  generate_with :openai, model: "gpt-4o"
end
```

Concerns let you:
- Share tool actions across multiple agents
- Organize complex agents into logical modules
- Reuse common patterns (authentication, logging, data access)
- Test functionality independently

### Callbacks

Hook into the generation lifecycle:

```ruby
class MyAgent < ApplicationAgent
  before_generation :load_context
  after_generation :log_response

  def chat
    prompt message: params[:message]
  end

  private

  def load_context
    @user = User.find(params[:user_id])
  end

  def log_response
    Rails.logger.info "Generated response"
  end
end
```

See [Callbacks](/agents/callbacks) for complete documentation.

### Streaming

Stream responses in real-time:

```ruby
class StreamingAgent < ApplicationAgent
  on_stream :broadcast_chunk

  def chat
    prompt message: params[:message], stream: true
  end

  private

  def broadcast_chunk(chunk)
    ActionCable.server.broadcast("chat", content: chunk.delta)
  end
end
```

See [Streaming](/agents/streaming) for complete documentation.

## Complete Example

Multi-action agent with views and callbacks:

::: code-group
```ruby [travel_agent.rb]
class TravelAgent < ApplicationAgent
  before_action :set_user

  def search
    @departure = params[:departure]
    @destination = params[:destination]
    @results = params[:results] || []
    prompt(content_type: :html)
  end

  def book
    @flight_id = params[:flight_id]
    @passenger_name = params[:passenger_name]
    @confirmation_number = params[:confirmation_number]
    prompt(content_type: :text)
  end

  private

  def set_user
    @user = params[:user] || Guest.new
  end
end
```

```erb [search.html.erb]
<h2>Search Results</h2>
<p>From <%= @departure %> to <%= @destination %></p>
<ul>
<% @results.each do |flight| %>
  <li><%= flight[:airline] %> - $<%= flight[:price] %></li>
<% end %>
</ul>
```

```erb [book.text.erb]
Booking flight <%= @flight_id %>
Passenger: <%= @passenger_name %>
Confirmation: <%= @confirmation_number %>
```
:::

**Usage:**

```ruby
# Search with HTML view
response = TravelAgent.with(
  departure: "NYC",
  destination: "LAX",
  results: [{ airline: "AA", price: 250 }]
).search.generate_now

# Book with text view
response = TravelAgent.with(
  flight_id: "AA123",
  passenger_name: "John Doe"
).book.generate_now
```

## Learn More

**Core Features:**
- [Generation](/agents/generation) - Execution patterns and response objects
- [Instructions](/agents/instructions) - System prompts that guide behavior
- [Callbacks](/agents/callbacks) - Lifecycle hooks and event handling
- [Streaming](/agents/streaming) - Real-time response updates
- [Error Handling](/agents/error-handling) - Retries and graceful degradation

**Related Topics:**
- [Tool Calling](/actions/tool-calling) - Use agent actions as AI-callable tools
- [Structured Output](/actions/structured-output) - Extract typed data with schemas
- [Embeddings](/actions/embeddings) - Vector generation for semantic search
- [Testing](/framework/testing) - Test agents and concerns
- [Instrumentation](/framework/instrumentation) - Monitor with notifications
