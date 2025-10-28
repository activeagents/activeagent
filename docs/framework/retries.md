---
title: Retries
description: Automatic retry mechanisms for handling rate limits, timeouts, and transient errors using provider-native SDK retry strategies with exponential backoff.
---
# {{ $frontmatter.title }}

LLM service APIs are inherently unstable, with requests frequently failing due to rate limits, temporary outages, network issues, and other transient errors. ActiveAgent relies on the built-in retry mechanisms provided by each provider's underlying SDK (ruby-openai, anthropic-rb, etc.), which implement sophisticated retry strategies with exponential backoff and rate limit handling.

## Provider-Native Retries

Each provider SDK includes its own retry logic that's specifically tuned for that provider's API:

**When retries trigger:**
- Network timeouts and connection errors
- Rate limit responses (429 status codes)
- Temporary server errors (500, 502, 503, 504)
- Socket errors and DNS failures
- Provider-specific transient errors

**Retry behavior:**
- Automatic exponential backoff
- Rate limit header awareness
- Jitter to prevent thundering herd
- Provider-optimized retry policies
- After max retries, an exception is raised

## Configuration

### OpenAI and OpenRouter

Both OpenAI and OpenRouter use the ruby-openai gem which provides comprehensive retry configuration:

```ruby
# config/activeagent.yml
openai:
  service: "OpenAI"
  access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
  max_retries: 5           # Number of retry attempts (default: 3)
  timeout: 600.0           # Total request timeout in seconds (default: 120)
  initial_retry_delay: 1.0 # Initial delay between retries (default: 1.0)
  max_retry_delay: 8.0     # Maximum delay between retries (default: 8.0)
```

The ruby-openai gem automatically:
- Retries on network errors and rate limits
- Uses exponential backoff with jitter
- Respects Retry-After headers from the API
- Handles 429, 500, 502, 503, 504 status codes

### Anthropic

The Anthropic provider uses the anthropic-rb gem with similar retry configuration:

```ruby
# config/activeagent.yml
anthropic:
  service: "Anthropic"
  access_token: <%= Rails.application.credentials.dig(:anthropic, :access_token) %>
  max_retries: 5           # Number of retry attempts (default: 2)
  timeout: 600.0           # Total request timeout in seconds (default: 600)
  initial_retry_delay: 0.5 # Initial delay between retries (default: 0.5)
  max_retry_delay: 2.0     # Maximum delay between retries (default: 2.0)
```

### Ollama

Ollama runs locally and typically doesn't need extensive retry configuration, but you can still configure timeouts:

```ruby
# config/activeagent.yml
ollama:
  service: "Ollama"
  host: "http://localhost:11434"
  timeout: 300.0  # Adjust for long-running local models
```

## Per-Agent Configuration

You can override retry settings on a per-agent basis:

```ruby
class MyAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    max_retries: 10,  # More aggressive retries for critical agents
    timeout: 1200.0
end
```

## Disabling Retries

To disable retries completely (not recommended for production):

```ruby
# config/activeagent.yml
openai:
  service: "OpenAI"
  access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
  max_retries: 0  # Disable retries
```

## Monitoring Retries

Use instrumentation to monitor API calls and detect retry patterns:

```ruby
ActiveSupport::Notifications.subscribe("generate.active_agent") do |name, start, finish, id, payload|
  duration = finish - start

  # Long durations may indicate retries occurred
  if duration > 30
    Rails.logger.warn("Generation took #{duration}s, agent: #{payload[:agent_class]}")
  end

  if payload[:error]
    Rails.logger.error("Generation failed: #{payload[:error]}")
  end
end
```

Provider SDKs may also log retry attempts. Enable debug logging to see detailed retry information:

```ruby
# For ruby-openai debugging
ENV['OPENAI_LOG'] = 'debug'

# For general Rails logging
ActiveAgent.configure do |config|
  config.logger.level = Logger::DEBUG
end
```

## Advanced Retry Strategies

For advanced retry patterns beyond what the provider SDKs offer, consider:

### Background Job Retries

Use Sidekiq's retry mechanism for job-level retries:

```ruby
class GenerationJob < ApplicationJob
  queue_as :default

  retry_on Net::ReadTimeout, wait: :exponentially_longer, attempts: 10
  retry_on SomeProvider::RateLimitError, wait: 1.minute, attempts: 5

  def perform(agent_class, input)
    agent_class.constantize.generate(input:)
  end
end
```

## Error Handling

For comprehensive error handling patterns including exception handlers and recovery strategies, see **[Error Handling](/agents/error_handling)**.

## Provider Documentation

Each provider SDK has detailed documentation on their retry implementation:

- **[ruby-openai](https://github.com/alexrudall/ruby-openai)** - OpenAI and OpenRouter
- **[anthropic-rb](https://github.com/alexrudall/anthropic)** - Anthropic Claude
- **[ruby-ollama](https://github.com/gbaptista/ollama-ai)** - Ollama (local)

## Related Documentation

- **[Configuration](/framework/configuration)** - Framework and provider configuration
- **[Rails Integration](/framework/rails)** - Rails-specific configuration and setup
- **[Testing](/framework/testing)** - Test configuration and mock providers
- **[Error Handling](/agents/error_handling)** - Agent-level error handling
- **[Instrumentation](/framework/instrumentation)** - Monitoring and logging
- **[Providers](/providers)** - Provider-specific documentation
