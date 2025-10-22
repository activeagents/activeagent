# Retries

LLM service APIs are inherently unstable, with requests frequently failing due to rate limits, temporary outages, network issues, and other transient errors. To handle this reality, ActiveAgent includes a basic built-in retry system that automatically retries failed requests.

**Important:** The built-in retry system is designed for development and light usage. For production environments, you should implement a custom retry strategy using a library like [Retriable](https://github.com/kamui/retriable) or [Sidekiq's retry mechanism](https://github.com/sidekiq/sidekiq/wiki/Error-Handling) that provides exponential backoff, jitter, and sophisticated retry policies.

## Default Retry Behavior

By default, ActiveAgent automatically retries failed requests up to 3 times when network errors occur.

**When retries trigger:**
- Network timeouts and connection errors
- Socket errors and DNS failures
- Any exception class listed in `retries_on`

**Retry behavior:**
- Retries are automatic and transparent
- Exponential backoff: 1s, 2s, 4s `(2^(attempt-1) seconds)`
- Original request is repeated with same parameters
- After max retries, the original exception is raised

## Configuration

### Disabling Retries

Disable automatic retries completely:

```ruby
ActiveAgent.configure do |config|
  config.retries = false
end
```

### Adjusting Retry Count

Change the maximum number of retry attempts:

```ruby
ActiveAgent.configure do |config|
  config.retries = true
  config.retries_count = 5  # Retry up to 5 times
end
```

### Custom Exception Classes

Add custom exception classes that should trigger retries:

```ruby
ActiveAgent.configure do |config|
  config.retries = true
  config.retries_on = [
    Errno::ECONNRESET,
    Errno::ETIMEDOUT,
    SocketError,
    Timeout::Error,
    CustomNetworkError,      # Add your custom error
    AnotherTransientError    # Multiple custom errors
  ]
end
```

Or append to the default list:

```ruby
ActiveAgent.configure do |config|
  config.retries_on << CustomNetworkError
  config.retries_on << AnotherTransientError
end
```

## Per-Provider

Some providers have their own built-in retry mechanisms. You can disable ActiveAgent's retries and rely on the provider's implementation:

```ruby
# Disable ActiveAgent retries
ActiveAgent.configure do |config|
  config.retries = false
end

# Configure provider-specific retries in active_agent.yml
anthropic:
  service: "Anthropic"
  access_token: <%= Rails.application.credentials.dig(:anthropic, :access_token) %>
  max_retries: 5  # Anthropic's built-in retry config
  timeout: 600.0
```

See individual provider documentation for their retry capabilities:

- **[Anthropic Provider](/providers/anthropic)** - Has `max_retries` configuration
- **[OpenAI Provider](/providers/open_ai)** - Uses ruby-openai gem retry logic
- **[OpenRouter Provider](/providers/open_router)** - Inherits OpenAI configuration
- **[Ollama Provider](/providers/ollama)** - Local calls typically don't need retries

## Per-Agent

Retry settings can also be configured on a per-agent basis, overriding the global configuration:

```ruby
class MyAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    retries: true,
    retries_count: 5,
    retries_on: [Net::ReadTimeout, CustomNetworkError]
end
```

For more advanced error handling patterns including exception handlers and recovery strategies, see **[Error Handling](/agents/error-handling)**.


## Custom Retry Strategies

For more sophisticated retry logic, provide a custom retry strategy using a Proc or lambda:

### Using Retriable Gem

```ruby
# Gemfile
gem 'retriable'

# Configuration
ActiveAgent.configure do |config|
  config.retries = ->(block) {
    Retriable.retriable(
      tries: 5,
      on: [Net::ReadTimeout, Timeout::Error],
      base_interval: 1.0,
      multiplier: 2.0,
      rand_factor: 0.5
    ) do
      block.call
    end
  }
end
```

### Conditional Retry Logic

Retry based on specific conditions:

```ruby
ActiveAgent.configure do |config|
  config.retries = ->(block) {
    attempts = 0
    max_attempts = 3

    begin
      attempts += 1
      block.call
    rescue StandardError => e
      # Only retry on specific HTTP status codes
      if e.respond_to?(:response) &&
         [429, 502, 503, 504].include?(e.response.code.to_i) &&
         attempts < max_attempts

        # Extract retry-after header if present
        retry_after = e.response.headers['Retry-After']
        sleep(retry_after ? retry_after.to_i : 2)
        retry
      else
        raise e
      end
    end
  }
end
```

## Monitoring Retries

Use instrumentation to monitor retry behavior:

```ruby
ActiveSupport::Notifications.subscribe("generate.active_agent") do |name, start, finish, id, payload|
  if payload[:error]
    Rails.logger.warn("Generation failed: #{payload[:error]}")
  end

  duration = finish - start
  if duration > 5
    Rails.logger.warn("Generation took #{duration}s - may have retried")
  end
end
```

See [Instrumentation](/framework/instrumentation) for detailed monitoring options.

## Related Documentation

- **[Configuration](/framework/configuration)** - Framework and provider configuration
- **[Instrumentation](/framework/instrumentation)** - Monitoring and logging
- **[Providers](/framework/providers)** - Provider-specific behavior and configuration
