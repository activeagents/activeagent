# Error Handling

LLM APIs are inherently unreliable—rate limits, network failures, and service outages are part of normal operation. ActiveAgent provides multiple layers of error handling to build resilient agents that gracefully handle failures.

## Overview

Error handling in ActiveAgent works at three levels:

1. **Retry Logic** - Automatically retry transient failures
2. **Exception Handlers** - Transform exceptions into fallback responses
3. **Rescue Handlers** - Application-level error recovery with callbacks

## Retry Configuration

Control how agents retry failed requests. See **[Retries](/framework/retries)** for complete retry documentation.

### Global Retry Settings

```ruby
ActiveAgent.configure do |config|
  config.retries = true
  config.retries_count = 3
  config.retries_on = [
    Errno::ECONNRESET,
    Errno::ETIMEDOUT,
    SocketError,
    Timeout::Error
  ]
end
```

### Per-Agent Retry Configuration

Override global settings for specific agents:

```ruby
class RobustAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    retries: true,
    retries_count: 5,
    retries_on: [Net::ReadTimeout, Timeout::Error, RateLimitError]

  def process
    prompt instructions: "Process the data"
  end
end
```

### Custom Retry Strategy

Implement sophisticated retry logic with exponential backoff:

```ruby
class ProductionAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    retries: ->(block) {
      Retriable.retriable(
        tries: 5,
        on: [Net::ReadTimeout, RateLimitError],
        base_interval: 1.0,
        multiplier: 2.0,
        max_interval: 30.0,
        rand_factor: 0.5
      ) { block.call }
    }

  def process
    prompt instructions: "Critical operation"
  end
end
```

## Exception Handlers

Exception handlers catch errors after retries are exhausted and provide fallback behavior:

```ruby
class GracefulAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    exception_handler: ->(exception) {
      Rails.logger.error("Generation failed: #{exception.message}")

      # Return fallback response
      {
        error: true,
        message: "Service temporarily unavailable",
        type: exception.class.name
      }
    }

  def chat(message)
    prompt message
  end
end

# Usage
result = GracefulAgent.with(message: "Hello").chat
# Returns fallback hash instead of raising exception
```

### Conditional Exception Handling

Handle different error types differently:

```ruby
class SmartAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    exception_handler: ->(exception) {
      case exception
      when RateLimitError
        Rails.logger.warn("Rate limited, queuing for later")
        SmartAgent.with(params).chat.generate_later
        { queued: true }

      when Timeout::Error
        Rails.logger.error("Timeout, using cached response")
        Rails.cache.fetch("last_response")

      when Net::ReadTimeout
        # Return nil to re-raise the exception
        nil

      else
        Rails.logger.error("Unexpected error: #{exception}")
        { error: "Unknown error occurred" }
      end
    }

  def chat
    prompt instructions: "You are a helpful assistant"
  end
end
```

## Rescue Handlers

Use ActiveAgent's rescue handlers for application-level error recovery with before/after callbacks:

```ruby
class MonitoredAgent < ApplicationAgent
  # Rescue specific exception types
  rescue_from Timeout::Error, with: :handle_timeout
  rescue_from RateLimitError, with: :handle_rate_limit
  rescue_from StandardError, with: :handle_generic_error

  def process(data)
    prompt instructions: "Analyze: #{data}"
  end

  private

  def handle_timeout(exception)
    Rails.logger.error("Timeout in #{self.class.name}: #{exception.message}")

    # Access to agent context
    ErrorNotifier.notify(
      exception,
      agent: self.class.name,
      action: action_name,
      params: params
    )

    # Return fallback
    { error: "Processing timed out", retry_after: 60 }
  end

  def handle_rate_limit(exception)
    retry_after = exception.retry_after || 60

    Rails.logger.warn("Rate limited, retry after #{retry_after}s")

    # Queue for later processing
    self.class.with(params).process(params[:data]).generate_later(wait: retry_after.seconds)

    { queued: true, retry_after: }
  end

  def handle_generic_error(exception)
    Rails.logger.error("Unexpected error: #{exception.class} - #{exception.message}")
    Sentry.capture_exception(exception)

    { error: "An unexpected error occurred" }
  end
end
```

See **[Rescue Handlers](/agents/concerns#rescue-handlers)** for complete documentation on rescue handler callbacks and patterns.

## Combining Strategies

Layer retry logic, exception handlers, and rescue handlers for robust error handling:

```ruby
class ProductionReadyAgent < ApplicationAgent
  # 1. Retry transient failures
  generate_with :openai,
    model: "gpt-4o",
    retries: ->(block) {
      Retriable.retriable(
        tries: 3,
        on: [Net::ReadTimeout, SocketError],
        base_interval: 2.0,
        multiplier: 2.0
      ) { block.call }
    },
    # 2. Transform provider errors
    exception_handler: ->(exception) {
      case exception
      when RateLimitError
        { rate_limited: true, retry_after: exception.retry_after }
      else
        nil  # Re-raise for rescue_from handlers
      end
    }

  # 3. Application-level error recovery
  rescue_from Timeout::Error, with: :handle_timeout
  rescue_from StandardError, with: :handle_error

  def analyze(content)
    prompt instructions: "Analyze the content", content:
  end

  private

  def handle_timeout(exception)
    Rails.logger.error("Analysis timeout: #{exception.message}")
    AnalysisJob.set(wait: 5.minutes).perform_later(params[:content])
    { queued: true }
  end

  def handle_error(exception)
    ErrorTracker.notify(exception, context: { agent: self.class.name })
    { error: "Analysis failed" }
  end
end
```

**How it works:**

1. **Retries** run first - automatic retries for transient network failures
2. **Exception handler** runs when retries exhausted - can transform errors or return nil to re-raise
3. **Rescue handlers** catch re-raised exceptions - application-level recovery with full agent context

## Error Monitoring

Monitor errors using ActiveSupport::Notifications:

```ruby
# config/initializers/active_agent.rb
ActiveSupport::Notifications.subscribe("generate.active_agent") do |name, start, finish, id, payload|
  if payload[:error]
    ErrorMetrics.increment("active_agent.errors", tags: [
      "agent:#{payload[:agent]}",
      "error:#{payload[:error].class.name}"
    ])
  end
end

# Monitor retry attempts
ActiveSupport::Notifications.subscribe("retry_attempt.provider.active_agent") do |name, start, finish, id, payload|
  Rails.logger.warn(
    "Retry attempt #{payload[:attempt]}/#{payload[:max_retries]} for #{payload[:provider]} " \
    "due to #{payload[:exception]}, waiting #{payload[:backoff_time]}s"
  )
end

# Monitor exhausted retries
ActiveSupport::Notifications.subscribe("retry_exhausted.provider.active_agent") do |name, start, finish, id, payload|
  ErrorMetrics.increment("active_agent.retries_exhausted", tags: [
    "provider:#{payload[:provider]}",
    "exception:#{payload[:exception]}"
  ])
end
```

See **[Instrumentation](/framework/instrumentation)** for complete monitoring documentation.

## Best Practices

### Fast Failure for Real-Time Applications

Disable retries for user-facing features that require fast responses:

```ruby
class RealtimeChatAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    retries: false,
    exception_handler: ->(exception) {
      { error: "Service temporarily unavailable" }
    }

  def chat(message)
    prompt message
  end
end
```

### Background Job Integration

Use background jobs for operations that can be retried over longer periods:

```ruby
class AsyncAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    retries: false,  # Let Sidekiq handle retries
    exception_handler: ->(exception) {
      # Log but re-raise so Sidekiq can retry the job
      Rails.logger.error("Generation failed: #{exception}")
      raise exception
    }

  def process(data)
    prompt instructions: "Process: #{data}"
  end
end

# In your job
class ProcessingJob < ApplicationJob
  retry_on RateLimitError, wait: :exponentially_longer, attempts: 10
  retry_on Net::ReadTimeout, wait: 30.seconds, attempts: 5
  discard_on SomeUnrecoverableError

  def perform(data)
    AsyncAgent.with(data:).process
  end
end
```

### Circuit Breaker Pattern

Prevent cascading failures with a circuit breaker:

```ruby
class CircuitBreakerAgent < ApplicationAgent
  cattr_accessor :circuit_breaker, default: CircuitBreaker.new

  generate_with :openai,
    model: "gpt-4o",
    retries: ->(block) {
      circuit_breaker.call do
        block.call
      end
    }

  def process
    prompt instructions: "Process data"
  end
end
```

### Graceful Degradation

Provide cached or simplified responses when the primary service fails:

```ruby
class ResilientAgent < ApplicationAgent
  generate_with :openai,
    model: "gpt-4o",
    exception_handler: ->(exception) {
      Rails.logger.warn("Primary provider failed, using fallback")

      # Try cheaper/faster model
      begin
        FallbackAgent.with(params).process.generate_now
      rescue
        # Return cached response
        Rails.cache.fetch("last_successful_response") do
          { error: "Service unavailable" }
        end
      end
    }

  def process
    prompt instructions: "Complex analysis"
  end
end
```

## Testing Error Handling

Test error scenarios in your agent specs:

```ruby
require "test_helper"

class MonitoredAgentTest < ActiveAgentTestCase
  test "handles timeout gracefully" do
    agent = MonitoredAgent.new

    # Simulate timeout
    agent.stub :api_call, -> { raise Timeout::Error } do
      result = agent.process("test data")

      assert_equal "Processing timed out", result[:error]
      assert_equal 60, result[:retry_after]
    end
  end

  test "handles rate limits with queuing" do
    error = RateLimitError.new("Rate limited")
    error.retry_after = 120

    agent = MonitoredAgent.new
    agent.stub :api_call, -> { raise error } do
      result = agent.process("test data")

      assert result[:queued]
      assert_equal 120, result[:retry_after]
    end
  end
end
```

## Related Documentation

- **[Retries](/framework/retries)** - Complete retry configuration and strategies
- **[Instrumentation](/framework/instrumentation)** - Monitoring errors and performance
- **[Callbacks](/agents/callbacks)** - Before/after hooks for error contexts
- **[Rescue Handlers](/agents/concerns#rescue-handlers)** - Application-level exception handling
