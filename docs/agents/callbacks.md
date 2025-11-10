---
title: Callbacks
description: Control agent lifecycle with generation, prompting, embedding, and streaming callbacks for setup, validation, cleanup, and real-time response handling.
---
# {{ $frontmatter.title }}

ActiveAgent provides callbacks for four different lifecycles:

- **Generation callbacks** (`before_generation`, `after_generation`, `around_generation`) - Wrap both prompting and embedding operations for rate limiting, authentication, and logging
- **Prompting callbacks** (`before_prompt`, `after_prompt`, `around_prompt`) - Specific to prompt execution
- **Embedding callbacks** (`before_embed`, `after_embed`, `around_embed`) - Specific to embedding operations
- **Streaming callbacks** (`on_stream_open`, `on_stream`, `on_stream_close`) - Handle real-time streaming responses as they arrive

Use generation callbacks for cross-cutting concerns, prompting/embedding callbacks for operation-specific behavior, and streaming callbacks for processing responses in real-time.

## Generation Callbacks

Generation callbacks wrap both prompting and embedding operations for rate limiting, authentication, and resource management.

### Before Generation

Runs before any generation executes. Use for setup, rate limiting, or validation:

<<< @/../test/docs/agents/callbacks_examples_test.rb#before_generation {ruby:line-numbers}

### After Generation

Runs after any generation completes. Use for logging, usage tracking, or cleanup:

<<< @/../test/docs/agents/callbacks_examples_test.rb#after_generation {ruby:line-numbers}

After callbacks are skipped if the callback chain is terminated with `throw :abort`.

### Around Generation

Wraps the entire generation process. Use for timing, transactions, or resource management:

<<< @/../test/docs/agents/callbacks_examples_test.rb#around_generation {ruby:line-numbers}

### Rate Limiting Example

<<< @/../test/docs/agents/callbacks_examples_test.rb#rate_limiting {ruby:line-numbers}

## Prompting Callbacks

Prompting callbacks are specific to prompt execution:

<<< @/../test/docs/agents/callbacks_examples_test.rb#prompting_callbacks {ruby:line-numbers}

## Embedding Callbacks

Embedding callbacks are specific to embedding operations:

<<< @/../test/docs/agents/callbacks_examples_test.rb#embedding_callbacks_detailed {ruby:line-numbers}

## Streaming Callbacks

Streaming callbacks handle real-time streaming responses as they arrive:

<<< @/../test/docs/agents/callbacks_examples_test.rb#streaming_callbacks {ruby:line-numbers}

Use `on_stream_open` for initialization, `on_stream` to process each chunk, and `on_stream_close` for cleanup. See [Streaming](/agents/streaming) for complete documentation.

## Multiple and Conditional Callbacks

Register multiple callbacks and apply them conditionally with `:if` and `:unless`:

<<< @/../test/docs/agents/callbacks_examples_test.rb#multiple_conditional_callbacks {ruby:line-numbers}

Callbacks execute in registration order (before/around) or reverse order (after).

## Callback Control

Use `prepend_*`, `skip_*`, and `append_*` variants for all callback types:

<<< @/../test/docs/agents/callbacks_examples_test.rb#callback_control {ruby:line-numbers}

## Related Documentation

- [Agents](/agents) - Understanding the agent lifecycle
- [Generation](/agents/generation) - Execution patterns and response objects
- [Instructions](/agents/instructions) - System prompts that guide behavior
- [Actions](/actions) - Define agent capabilities
- [Messages](/actions/messages) - Work with conversation context
- [Error Handling](/agents/error_handling) - Handle failures in callbacks
- [Testing](/framework/testing) - Test callback functionality
- [Instrumentation](/framework/instrumentation) - Monitor callback execution
