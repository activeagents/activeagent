---
title: Telemetry & Observability
description: Collect and report agent traces to monitor AI operations, track costs, and debug generation flows with hosted or self-hosted observability.
---

# {{ $frontmatter.title }}

ActiveAgent includes built-in telemetry for collecting and reporting agent traces. Monitor your AI operations, track token usage and costs, and debug generation flows with comprehensive observability.

## Overview

The telemetry system captures:
- **Generation Traces**: Full lifecycle of agent generations
- **Token Usage**: Input, output, and thinking tokens per request
- **Tool Calls**: Invocations with timing and results
- **Errors**: Exceptions with backtraces for debugging
- **Performance Metrics**: Response times and latencies

## Quick Start

### Hosted Service (ActiveAgents.ai)

The fastest way to get started is with the hosted observability service:

```yaml
# config/active_agent.yml
development:
  openai:
    service: "OpenAI"
    access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>

  telemetry:
    enabled: true
    endpoint: https://api.activeagents.ai/v1/traces
    api_key: <%= Rails.application.credentials.dig(:activeagents, :api_key) %>
```

### Self-Hosted

For complete control, run your own telemetry endpoint:

```yaml
# config/active_agent.yml
production:
  telemetry:
    enabled: true
    endpoint: https://observability.mycompany.com/v1/traces
    api_key: <%= ENV["TELEMETRY_API_KEY"] %>
    service_name: my-rails-app
```

## Configuration

### YAML Configuration

Configure telemetry in your `config/active_agent.yml`:

```yaml
telemetry:
  enabled: true
  endpoint: https://api.activeagents.ai/v1/traces
  api_key: <%= Rails.application.credentials.dig(:activeagents, :api_key) %>
  sample_rate: 1.0        # 1.0 = 100%, 0.5 = 50%
  batch_size: 100         # Traces per batch
  flush_interval: 5       # Seconds between flushes
  service_name: my-app    # Override app name
  capture_bodies: false   # Include request/response bodies
  resource_attributes:    # Custom attributes for all traces
    deployment: production
    team: ai-platform
```

### Programmatic Configuration

Configure in an initializer for dynamic settings:

```ruby
# config/initializers/active_agent.rb
ActiveAgent::Telemetry.configure do |config|
  config.enabled = Rails.env.production?
  config.endpoint = ENV.fetch("TELEMETRY_ENDPOINT", "https://api.activeagents.ai/v1/traces")
  config.api_key = Rails.application.credentials.dig(:activeagents, :api_key)
  config.sample_rate = 1.0
  config.service_name = Rails.application.class.module_parent_name.underscore
end
```

### Rails Configuration

You can also configure via Rails config:

```ruby
# config/application.rb
config.active_agent.telemetry = {
  enabled: true,
  endpoint: "https://api.activeagents.ai/v1/traces",
  api_key: Rails.application.credentials.dig(:activeagents, :api_key)
}
```

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enabled` | Boolean | `false` | Enable telemetry collection |
| `endpoint` | String | `https://api.activeagents.ai/v1/traces` | Telemetry receiver URL |
| `api_key` | String | `nil` | Authentication token |
| `sample_rate` | Float | `1.0` | Sampling rate (0.0 - 1.0) |
| `batch_size` | Integer | `100` | Traces per batch before flush |
| `flush_interval` | Integer | `5` | Seconds between auto-flushes |
| `timeout` | Integer | `10` | HTTP request timeout |
| `capture_bodies` | Boolean | `false` | Include message bodies |
| `service_name` | String | App name | Service identifier |
| `environment` | String | `Rails.env` | Environment name |
| `resource_attributes` | Hash | `{}` | Custom trace attributes |
| `redact_attributes` | Array | `["password", "secret", ...]` | Keys to redact |

## Trace Structure

Each trace captures the complete generation lifecycle:

```
Trace: WeatherAgent.forecast
├── Span: agent.prompt (prompt preparation)
├── Span: llm.generate (API call)
│   ├── tokens: { input: 150, output: 75, total: 225 }
│   └── model: "gpt-4o"
└── Span: tool.get_weather (tool invocation)
    └── duration: 234ms
```

### Span Types

| Type | Description |
|------|-------------|
| `root` | Root span for the entire generation |
| `prompt` | Prompt preparation and rendering |
| `llm` | LLM API call |
| `tool` | Tool/function invocation |
| `thinking` | Extended thinking (Anthropic) |
| `embedding` | Embedding generation |
| `error` | Error handling |

## Manual Tracing

Add custom spans to your traces:

```ruby
class WeatherAgent < ApplicationAgent
  def forecast(location:)
    @location = location

    # Add custom span
    if ActiveAgent::Telemetry.enabled?
      span = ActiveAgent::Telemetry.span("geocode.lookup")
      span.set_attribute("location", location)
      coordinates = geocode_location(location)
      span.finish
    end

    prompt
  end
end
```

### Trace Block

Use the trace block for automatic timing and error handling:

```ruby
ActiveAgent::Telemetry.trace("custom.operation") do |span|
  span.set_attribute("user_id", current_user.id)
  span.set_attribute("operation", "data_enrichment")

  result = perform_operation

  span.set_tokens(input: 100, output: 50)
  result
end
```

## Sampling

Control trace volume with sampling:

```ruby
ActiveAgent::Telemetry.configure do |config|
  # Sample 10% of production traffic
  config.sample_rate = Rails.env.production? ? 0.1 : 1.0
end
```

Sampling is deterministic per-trace, so all spans within a trace are included or excluded together.

## Flushing & Shutdown

Traces are batched and sent asynchronously. Force flush when needed:

```ruby
# Flush buffered traces immediately
ActiveAgent::Telemetry.flush

# Graceful shutdown (flush and wait)
ActiveAgent::Telemetry.shutdown
```

### Rails Integration

Telemetry automatically flushes on Rails shutdown:

```ruby
# config/initializers/active_agent.rb
at_exit { ActiveAgent::Telemetry.shutdown }
```

## Self-Hosting

### Endpoint Requirements

Your telemetry endpoint must accept POST requests with:

**Headers:**
- `Content-Type: application/json`
- `Authorization: Bearer <api_key>`
- `X-Service-Name: <service_name>`
- `X-Environment: <environment>`

**Payload:**
```json
{
  "traces": [
    {
      "trace_id": "abc123...",
      "service_name": "my-app",
      "environment": "production",
      "timestamp": "2024-01-15T10:30:00.123456Z",
      "resource_attributes": {},
      "spans": [
        {
          "span_id": "def456",
          "trace_id": "abc123...",
          "parent_span_id": null,
          "name": "WeatherAgent.forecast",
          "type": "root",
          "start_time": "2024-01-15T10:30:00.123456Z",
          "end_time": "2024-01-15T10:30:01.234567Z",
          "duration_ms": 1111.11,
          "status": "OK",
          "attributes": {
            "agent.class": "WeatherAgent",
            "agent.action": "forecast"
          },
          "tokens": {
            "input": 150,
            "output": 75,
            "total": 225
          },
          "events": []
        }
      ]
    }
  ],
  "sdk": {
    "name": "activeagent",
    "version": "0.5.0",
    "language": "ruby",
    "runtime_version": "3.3.0"
  }
}
```

### Example Rails Endpoint

```ruby
# app/controllers/api/traces_controller.rb
class Api::TracesController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :authenticate_api_key!

  def create
    traces = params[:traces]

    traces.each do |trace|
      Trace.create!(
        trace_id: trace[:trace_id],
        service_name: trace[:service_name],
        environment: trace[:environment],
        spans: trace[:spans],
        timestamp: trace[:timestamp]
      )
    end

    head :accepted
  end

  private

  def authenticate_api_key!
    api_key = request.headers["Authorization"]&.gsub(/^Bearer /, "")
    head :unauthorized unless ApiKey.exists?(key: api_key)
  end
end
```

## Comparison with Instrumentation

ActiveAgent provides two complementary observability systems:

| Feature | Instrumentation | Telemetry |
|---------|-----------------|-----------|
| **Purpose** | Local logging & metrics | Distributed tracing |
| **Transport** | ActiveSupport::Notifications | HTTP POST |
| **Destination** | Rails logs, local metrics | Remote endpoint |
| **Use Case** | Debugging, local monitoring | Production observability |
| **Overhead** | Minimal | Async, batched |

Use **Instrumentation** for local development and debugging. Use **Telemetry** for production observability and analytics.

## Security Considerations

### Sensitive Data

By default, telemetry redacts common sensitive attributes:
- `password`, `secret`, `token`, `key`, `credential`, `api_key`

Add custom redactions:

```ruby
ActiveAgent::Telemetry.configure do |config|
  config.redact_attributes += ["ssn", "credit_card"]
end
```

### Message Bodies

Message bodies are **not captured by default**. Enable with caution:

```ruby
ActiveAgent::Telemetry.configure do |config|
  config.capture_bodies = true  # Only in controlled environments
end
```

## Troubleshooting

### Traces Not Appearing

1. **Check enabled status:**
   ```ruby
   puts ActiveAgent::Telemetry.enabled?  # Should be true
   ```

2. **Verify configuration:**
   ```ruby
   puts ActiveAgent::Telemetry.configuration.to_h
   ```

3. **Check logs for errors:**
   ```ruby
   ActiveAgent::Telemetry.configure do |config|
     config.logger = Rails.logger
   end
   ```

### High Memory Usage

Reduce batch size or increase flush frequency:

```ruby
ActiveAgent::Telemetry.configure do |config|
  config.batch_size = 25
  config.flush_interval = 2
end
```

## Related Documentation

- **[Instrumentation](/framework/instrumentation)** - Local logging with ActiveSupport::Notifications
- **[Usage Statistics](/actions/usage)** - Token usage and cost tracking
- **[Configuration](/framework/configuration)** - General framework configuration
