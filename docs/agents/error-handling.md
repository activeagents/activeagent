# Error Handling

ActiveAgent provides two complementary layers of error handling for building resilient agents:

1. **Retries** - Automatically retry transient network failures
2. **Rescue Handlers** - Application-level error recovery with agent context

## Retries

ActiveAgent automatically retries network failures 3 times with exponential backoff. Configure globally or per-agent:

<<< @/../test/docs/agents/error_handling_examples_test.rb#retries {ruby:line-numbers}

See **[Retries](/framework/retries)** for custom retry strategies, conditional logic, and monitoring.

## Rescue Handlers

Use `rescue_from` for application-level error recovery with full agent context. Handle different error types with specific strategies:

<<< @/../test/docs/agents/error_handling_examples_test.rb#rescue_handlers {ruby:line-numbers}

## Combining Strategies

Combine retries with rescue handlers for comprehensive error handling:

<<< @/../test/docs/agents/error_handling_examples_test.rb#combining_strategies {ruby:line-numbers}

**Execution flow:**

1. Retries run first for transient network failures
2. Rescue handlers catch exceptions after retries are exhausted

## Monitoring

Monitor errors using ActiveSupport::Notifications:

<<< @/../test/docs/agents/error_handling_examples_test.rb#monitoring {ruby:line-numbers}

See **[Instrumentation](/framework/instrumentation)** for complete monitoring documentation.

## Patterns

### Fast Failure for Real-Time

Disable retries and provide immediate fallback for user-facing features:

<<< @/../test/docs/agents/error_handling_examples_test.rb#fast_failure {ruby:line-numbers}

### Background Job Integration

Let job framework handle retries:

<<< @/../test/docs/agents/error_handling_examples_test.rb#background_job_integration {ruby:line-numbers}

### Graceful Degradation

Provide cached or simplified responses when primary service fails:

<<< @/../test/docs/agents/error_handling_examples_test.rb#graceful_degradation {ruby:line-numbers}

## Testing

Test error handling in your agent specs:

<<< @/../test/docs/agents/error_handling_examples_test.rb#testing_error_handling {ruby:line-numbers}

## Related Documentation

- **[Retries](/framework/retries)** - Retry configuration and strategies
- **[Instrumentation](/framework/instrumentation)** - Monitoring and logging
- **[Callbacks](/agents/callbacks)** - Before/after hooks
