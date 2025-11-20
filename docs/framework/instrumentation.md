---
title: Instrumentation and Logging
description: Monitor provider operations using ActiveSupport::Notifications. Track performance metrics, debug generation flows, and integrate with external monitoring services.
---
# {{ $frontmatter.title }}

ActiveAgent instruments all provider operations using `ActiveSupport::Notifications`.

::: warning Beta Feature
This instrumentation API is in beta and may change with Rails 8.1. Event names, payload structures, and subscriber interfaces could be updated as Rails evolves its instrumentation and events patterns.
:::

## Available Events

**Event namespaces:**
- **`.active_agent`** - Overall request/response lifecycle
- **`.provider.active_agent`** - Individual API calls in multi-turn conversations

### Core Events

| Event | When Triggered | Key Payload Data |
|-------|----------------|------------------|
| `prompt.active_agent` | After prompt completion | `model`, `message_count`, `stream`, `usage`, `finish_reason`, `response_model`, `response_id` |
| `prompt.provider.active_agent` | After individual API call | Same as above (per-call usage in multi-turn) |
| `embed.active_agent` | After embedding completion | `model`, `input_size`, `embedding_count`, `usage`, `response_model`, `response_id` |
| `embed.provider.active_agent` | After individual embed call | Same as above |

### Streaming Events

| Event | When Triggered | Key Payload Data |
|-------|----------------|------------------|
| `stream_open.active_agent` | Stream connection opens | Basic metadata |
| `stream_close.active_agent` | Stream connection closes | Basic metadata |
| `stream_chunk.active_agent` | Processing stream chunk | `chunk_type` (when available) |

### Tool and Processing Events

| Event | When Triggered | Key Payload Data |
|-------|----------------|------------------|
| `tool_call.active_agent` | Individual tool execution | `tool_name` |

### Infrastructure Events

| Event | When Triggered | Key Payload Data |
|-------|----------------|------------------|
| `process.active_agent` | Agent action processing | `agent`, `action`, `args`, `kwargs` |

## Built-in Log Subscriber

ActiveAgent automatically logs all provider operations at the `debug` level:

<<< @/../lib/active_agent/providers/log_subscriber.rb#log_subscriber_attach {ruby:line-numbers}

**Example output:**
```
[trace-123] [ActiveAgent] [OpenAI] Prompt completed: model=gpt-4o messages=2 stream=false tokens=150/75 finish=stop 543.2ms
[trace-456] [ActiveAgent] [OpenAI] Embed completed: model=text-embedding-ada-002 inputs=5 embeddings=5 tokens=150 89.1ms
```

### Controlling Log Verbosity

ActiveAgent inherits your Rails logger configuration automatically. Non-Rails apps: see [Configuration](/framework/configuration).

| Level | What's Logged |
|-------|---------------|
| `DEBUG` | All events with full detail |
| `INFO` | API calls and completions |
| `WARN` | Errors and retries only |
| `ERROR` | Failures only |
| `FATAL` | Nothing |

## Custom Event Subscribers

### Basic Subscription

```ruby
# Subscribe to prompt completions
ActiveSupport::Notifications.subscribe("prompt.active_agent") do |event|
  duration = event.duration
  provider = event.payload[:provider_module]
  model = event.payload[:model]

  Rails.logger.info "AI prompt: #{provider}/#{model} completed in #{duration}ms"
end

# Subscribe to all ActiveAgent events
ActiveSupport::Notifications.subscribe(/active_agent/) do |name, start, finish, id, payload|
  duration = (finish - start) * 1000
  Rails.logger.debug "Event: #{name} (#{duration.round(1)}ms)"
end
```

### Event Payload Data

**Common fields (all events):**
- `provider` - Provider name (`"OpenAI"`, `"Anthropic"`, `"Ollama"`)
- `provider_module` - Provider class
- `trace_id` - Unique identifier for tracking
- `event.duration` - Duration in milliseconds

**Prompt events:**
```ruby
{
  model: "gpt-4o",
  message_count: 2,
  stream: false,
  temperature: 0.7,          # when set
  max_tokens: 1000,          # when set
  has_tools: true,
  tool_count: 3,
  has_instructions: true,
  usage: {
    input_tokens: 100,
    output_tokens: 50,
    total_tokens: 150,
    cached_tokens: 25,       # when available
    reasoning_tokens: 10     # when available
  },
  finish_reason: "stop",     # "stop", "length", "tool_calls"
  response_model: "gpt-4o",
  response_id: "chatcmpl-123"
}
```

::: tip Usage Object Details
See [Usage Statistics](/actions/usage) for field definitions and provider-specific metrics.
:::

**Embed events:**
```ruby
{
  model: "text-embedding-ada-002",
  input_size: 5,
  embedding_count: 5,
  encoding_format: "float",  # when set
  dimensions: 1536,          # when set
  usage: {
    input_tokens: 150,
    total_tokens: 150
  },
  response_model: "text-embedding-ada-002",
  response_id: "emb-123"
}
```

**Other events:**
- `tool_name` - Tool being executed
- `chunk_type` - Stream chunk type (when available)
- `uri_base`, `exception`, `message` - Connection error details

### Common Use Cases

**Performance Monitoring:**

Track slow API calls and alert when thresholds are exceeded:

```ruby
ActiveSupport::Notifications.subscribe("prompt.active_agent") do |event|
  if event.duration > 5000
    SlackNotifier.alert(
      "Slow AI prompt: #{event.duration}ms",
      provider: event.payload[:provider_module],
      model: event.payload[:model],
      trace_id: event.payload[:trace_id]
    )
  end
end
```

**Cost Tracking:**

```ruby
ActiveSupport::Notifications.subscribe("prompt.active_agent") do |event|
  usage = event.payload[:usage]
  next unless usage

  CostTracker.record(
    provider: event.payload[:provider],
    model: event.payload[:response_model],
    input_tokens: usage[:input_tokens],
    output_tokens: usage[:output_tokens],
    cached_tokens: usage[:cached_tokens],
    reasoning_tokens: usage[:reasoning_tokens]
  )
end
```

**Analytics:**

```ruby
ActiveSupport::Notifications.subscribe("prompt.active_agent") do |event|
  Analytics.track(
    "ai.prompt",
    model: event.payload[:model],
    tokens: event.payload[:usage]&.fetch(:total_tokens),
    duration: event.duration
  )
end
```

**Tool Tracking:**

```ruby
ActiveSupport::Notifications.subscribe("tool_call.active_agent") do |event|
  Analytics.track(
    "tool.call",
    name: event.payload[:tool_name],
    duration: event.duration
  )
end
```

## Custom Log Subscriber

Create a custom log subscriber to control formatting, verbosity, and output destinations:

```ruby
# config/initializers/active_agent_logging.rb
class CustomAgentLogger < ActiveAgent::Providers::LogSubscriber
  def prompt(event)
    return unless logger.info?

    provider = event.payload[:provider_module]
    model = event.payload[:model]
    duration = event.duration.round(1)

    info "🤖 #{provider}/#{model}: #{duration}ms"
  end

  def tool_call(event)
    return unless logger.debug?

    tool_name = event.payload[:tool_name]
    duration = event.duration.round(1)
    debug "🔧 Tool: #{tool_name} (#{duration}ms)"
  end

  def connection_error(event)
    provider = event.payload[:provider_module]
    uri = event.payload[:uri_base]
    error "❌ #{provider} connection failed: #{uri}"
  end
end

# Replace the default subscriber
ActiveAgent::Providers::LogSubscriber.detach_from :active_agent
ActiveAgent::Providers::LogSubscriber.detach_from :"provider.active_agent"
CustomAgentLogger.attach_to :active_agent
CustomAgentLogger.attach_to :"provider.active_agent"
```

## Related Documentation

- **[Usage Statistics](/actions/usage)** - Understand usage fields and provider-specific metrics
- **[Agents](/agents)** - Learn about agent lifecycle, callbacks, and the generation cycle
- **[Callbacks](/agents/callbacks)** - Understand callback hooks like `before_generation` and `after_generation`
- **[Providers](/providers)** - Explore provider-specific behavior and configuration
- **[Testing](/framework/testing)** - Test agents and instrumentation in your test suite
- **[Configuration](/framework/configuration)** - Configure instrumentation behavior across environments
