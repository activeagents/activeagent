# Instrumentation and Logging

ActiveAgent instruments all provider operations using `ActiveSupport::Notifications`, enabling detailed monitoring, logging, and custom event handling. Track performance metrics, debug generation flows, and integrate with external monitoring services.

::: warning Beta Feature
This instrumentation API is in beta and may change with Rails 8.1. Event names, payload structures, and subscriber interfaces could be updated as Rails evolves its instrumentation and events patterns.
:::

## Available Events

ActiveAgent publishes instrumentation events throughout the generation lifecycle. Subscribe to these events to monitor operations, track performance, and handle errors:

### Provider Events

| Event | When Triggered | Description |
|-------|----------------|-------------|
| `prompt_start.provider.active_agent` | Before prompt request | Prompt generation initiated |
| `embed_start.provider.active_agent` | Before embedding request | Embedding generation initiated |
| `request_prepared.provider.active_agent` | After request built | Request prepared with formatted messages |
| `api_call.provider.active_agent` | After API response | Provider API call completed |
| `embed_call.provider.active_agent` | After embedding API response | Embedding API call completed |
| `prompt_complete.provider.active_agent` | After full generation | Entire generation cycle finished |

### Streaming Events

| Event | When Triggered | Description |
|-------|----------------|-------------|
| `stream_open.provider.active_agent` | Stream connection starts | Streaming connection opened |
| `stream_close.provider.active_agent` | Stream connection ends | Streaming connection closed |

### Processing Events

| Event | When Triggered | Description |
|-------|----------------|-------------|
| `messages_extracted.provider.active_agent` | After parsing response | Messages extracted from API response |
| `tool_calls_processing.provider.active_agent` | Before executing tools | Tool/function calls detected and processing |
| `multi_turn_continue.provider.active_agent` | After tool execution | Continuing conversation after tool use |
| `tool_execute.provider.active_agent` | During tool execution | Individual tool being executed |

### Error Events

| Event | When Triggered | Description |
|-------|----------------|-------------|
| `retry_attempt.provider.active_agent` | After failed request | Retry attempt after error |
| `retry_exhausted.provider.active_agent` | After max retries | All retry attempts exhausted |

### Agent Events

| Event | When Triggered | Description |
|-------|----------------|-------------|
| `process.active_agent` | During agent action | Agent action processing |


## Built-in Log Subscriber

ActiveAgent includes a `LogSubscriber` that automatically logs all provider operations at the `debug` level when Rails loads:

<<< @/../lib/active_agent/railtie.rb#log_subscriber {ruby:line-numbers}

Logs include trace IDs for tracking related operations, provider names, timing information, and operation details.

**Example log output:**
```
[trace-123] [ActiveAgent] [OpenAI::Responses] Starting prompt request
[trace-123] [ActiveAgent] [OpenAI::Responses] Prepared request with 2 message(s)
[trace-123] [ActiveAgent] [OpenAI::Responses] API call completed in 543.2ms (streaming: false)
[trace-123] [ActiveAgent] [OpenAI::Responses] Prompt completed with 3 message(s) in stack (total: 567.1ms)
```

### Controlling Log Verbosity

By default, ActiveAgent automatically inherits the logger, log level, and colorization settings from your Rails application via the Railtie. This means instrumentation logging respects your Rails environment configuration without additional setup.

If you're not using Rails, see the [Configuration](/framework/configuration) documentation for details on configuring logging behavior.

**Log Level Guidance:**

- **`DEBUG`** - All events logged with full detail (development default)
- **`INFO`** - Important operations like API calls and completions (production default)
- **`WARN`** - Only errors and retries (quiet production)
- **`ERROR`** - Only failures (minimal logging)
- **`FATAL`** - Disable instrumentation logging entirely

## Custom Event Subscribers

Subscribe to specific events or all ActiveAgent events for monitoring, metrics collection, debugging, and integration with external services.

### Basic Subscription

```ruby
# Subscribe to a specific event
ActiveSupport::Notifications.subscribe("api_call.provider.active_agent") do |event|
  duration = event.duration
  provider = event.payload[:provider_module]
  trace_id = event.payload[:trace_id]

  # Your custom handling
  Rails.logger.info "AI API call: #{provider} completed in #{duration}ms (trace: #{trace_id})"
end

# Subscribe to all ActiveAgent events
ActiveSupport::Notifications.subscribe(/active_agent/) do |name, start, finish, id, payload|
  duration = (finish - start) * 1000
  Rails.logger.debug "Event: #{name} (#{duration.round(1)}ms)"
end
```

### Event Payload Data

Each event includes contextual data in the payload hash. Common fields across events:

| Field | Type | Description |
|-------|------|-------------|
| `trace_id` | String | Unique identifier for tracking related operations across the request lifecycle |
| `provider_module` | String | Provider class handling the request (e.g., `"OpenAI::Responses"`) |
| `message_count` | Integer | Number of messages in the context (varies by event) |
| `streaming` | Boolean | Whether streaming is enabled for this request |
| `tool_count` | Integer | Number of tool calls being processed (tool events only) |
| `usage` | Hash | Token usage information from provider response |
| `attempt` | Integer | Current retry attempt number (retry events only) |
| `max_retries` | Integer | Maximum retry attempts configured (retry events only) |
| `exception` | String | Exception class name (error events only) |

Access duration via `event.duration` (in milliseconds).

### Common Use Cases

**Performance Monitoring:**

Track slow API calls and alert when thresholds are exceeded:

```ruby
ActiveSupport::Notifications.subscribe("api_call.provider.active_agent") do |event|
  if event.duration > 5000
    SlackNotifier.alert(
      "Slow AI API call: #{event.duration}ms",
      provider: event.payload[:provider_module],
      trace_id: event.payload[:trace_id]
    )
  end
end
```

**Cost Tracking:**

Monitor token usage and calculate costs by provider:

```ruby
ActiveSupport::Notifications.subscribe("prompt_complete.provider.active_agent") do |event|
  usage = event.payload[:usage]
  next unless usage

  CostTracker.record(
    provider: event.payload[:provider_module],
    prompt_tokens: usage[:prompt_tokens],
    completion_tokens: usage[:completion_tokens],
    total_tokens: usage[:total_tokens],
    trace_id: event.payload[:trace_id]
  )
end
```

**Error Tracking:**

Capture failures and send to error monitoring service:

```ruby
ActiveSupport::Notifications.subscribe("retry_exhausted.provider.active_agent") do |event|
  Sentry.capture_message(
    "AI request failed after #{event.payload[:max_retries]} retries",
    level: :error,
    extra: {
      trace_id: event.payload[:trace_id],
      provider: event.payload[:provider_module],
      exception: event.payload[:exception]
    }
  )
end
```

**Tool Usage Analytics:**

Track which tools are being called and how often:

```ruby
ActiveSupport::Notifications.subscribe("tool_execute.provider.active_agent") do |event|
  Analytics.increment(
    "agent.tool_usage",
    tags: {
      tool_name: event.payload[:tool_name],
      agent_class: event.payload[:agent_class]
    }
  )
end
```

## Custom Log Subscriber

Create a custom log subscriber to control formatting, verbosity, and output destinations:

```ruby
# config/initializers/active_agent_logging.rb
class CustomAgentLogger < ActiveAgent::LogSubscriber
  def api_call(event)
    return unless logger.info? # Only log at info level or higher

    duration = event.duration.round(1)
    provider = event.payload[:provider_module]

    info "🤖 #{provider} API call: #{duration}ms"
  end

  def prompt_complete(event)
    return unless logger.info?

    message_count = event.payload[:message_count]
    duration = event.duration.round(1)

    info "✅ Prompt completed: #{message_count} messages in #{duration}ms"
  end

  def tool_execute(event)
    return unless logger.debug?

    tool_name = event.payload[:tool_name]
    debug "🔧 Tool executed: #{tool_name}"
  end

  def retry_attempt(event)
    attempt = event.payload[:attempt]
    max_retries = event.payload[:max_retries]
    exception = event.payload[:exception]

    warn "⚠️  Retry attempt #{attempt}/#{max_retries} (#{exception})"
  end
end

# Replace the default subscriber
ActiveAgent::LogSubscriber.detach_from :provider.active_agent
CustomAgentLogger.attach_to :provider.active_agent
```

## Common Debugging Scenarios

**Slow generation:**
1. Check `api_call` event duration
2. Look for multiple `tool_execute` events (multi-turn overhead)
3. Check `message_count` in `request_prepared` (large context)

**Tool execution issues:**
1. Enable debug logging to see `tool_execute` events
2. Check `tool_calls_processing` for tool count
3. Look for `multi_turn_continue` to verify conversation flow

**Retry behavior:**
1. Watch for `retry_attempt` events with backoff times
2. Check `retry_exhausted` for ultimate failures
3. Review exception types in retry payloads

## Related Documentation

- **[Agents](/framework/agents)** - Learn about agent lifecycle, callbacks, and the generation cycle
- **[Callbacks](/agents/callbacks)** - Understand callback hooks like `before_generation` and `after_generation`
- **[Providers](/framework/providers)** - Explore provider-specific behavior and configuration
- **[Testing](/framework/testing)** - Test agents and instrumentation in your test suite
- **[Configuration](/framework/rails-integration)** - Configure instrumentation behavior across environments
