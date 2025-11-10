---
title: Streaming
description: Stream responses from AI providers in real-time using callbacks that execute at different points in the streaming lifecycle.
---
# {{ $frontmatter.title }}

Stream responses from AI providers in real-time using ActiveAgent's streaming callbacks. This guide covers handling streaming responses with callbacks that execute at different points in the streaming lifecycle.

## Overview

ActiveAgent provides three streaming callbacks:

- `on_stream_open` - Invoked when the stream begins
- `on_stream` - Invoked for every chunk received during streaming
- `on_stream_close` - Invoked when the stream completes

Callbacks automatically receive a `StreamChunk` object if they accept a parameter, providing access to the current message state and incremental delta content.

## Basic Streaming

Enable streaming by passing `stream: true` to your agent or prompt:

<<< @/../test/docs/agents/streaming_examples_test.rb#basic_streaming_agent {ruby:line-numbers} [agent.rb]

<<< @/../test/docs/agents/streaming_examples_test.rb#basic_streaming_usage {ruby:line-numbers} [usage.rb]

## StreamChunk Object

Each callback receives a `StreamChunk` with two attributes:

- `message` - The current message object from the provider (accumulated state)
- `delta` - The incremental content for this specific chunk (may be `nil`)

The `delta` contains only the new content received in the current chunk, while `message` contains the accumulated message state. Not all chunks contain a delta—some may only contain metadata updates.

```ruby
def log_chunk(chunk)
  # Delta contains only new content for this chunk
  Rails.logger.debug("New content: #{chunk.delta}")

  # Message contains accumulated provider response
  Rails.logger.debug("Full message so far: #{chunk.message.inspect}")
end
```

## Lifecycle Callbacks

Use callbacks to handle different points in the streaming lifecycle:

### on_stream_open

Invoked when streaming begins. Use this to initialize state:

<<< @/../test/docs/agents/streaming_examples_test.rb#lifecycle_open {ruby:line-numbers}


### on_stream

Invoked for every chunk. Keep processing lightweight:

<<< @/../test/docs/agents/streaming_examples_test.rb#lifecycle_chunk {ruby:line-numbers}

### on_stream_close

Invoked when streaming completes. Use for cleanup and final processing:


<<< @/../test/docs/agents/streaming_examples_test.rb#lifecycle_close {ruby:line-numbers}

## Callback Options

### Optional Parameters

Callbacks can accept a chunk parameter or omit it:

<<< @/../test/docs/agents/streaming_examples_test.rb#callbacks_parameters_optional {ruby:line-numbers}

### Multiple Callbacks

Register multiple callbacks that execute in order:

<<< @/../test/docs/agents/streaming_examples_test.rb#callbacks_parameters_multiple {ruby:line-numbers}

### Conditional Execution

Use `:if` and `:unless` to conditionally execute callbacks:

<<< @/../test/docs/agents/streaming_examples_test.rb#callbacks_parameters_conditional {ruby:line-numbers}

### Block Syntax

Define callbacks inline with blocks:

<<< @/../test/docs/agents/streaming_examples_test.rb#callbacks_paramters_blocks {ruby:line-numbers}

## Provider Support

Streaming is supported by these providers:

- **OpenAI** - All chat completion models (GPT-4, GPT-3.5 Turbo, etc.)
- **Anthropic** - Claude models (Claude 3 and Claude 4 families)
- **OpenRouter** - Most models with streaming capability
- **Ollama** - Local models with streaming support

See the [providers documentation](/docs/providers) for provider-specific configuration.

## Best Practices

### Guard Against Nil Deltas

Always check for `nil` delta values:

```ruby
def process_chunk(chunk)
  return unless chunk.delta
  print chunk.delta
end
```

### Initialize State in on_stream_open

Set up buffers and counters before streaming:

```ruby
on_stream_open { @buffer = [] }
on_stream { |chunk| @buffer << chunk.delta if chunk.delta }
on_stream_close { process(@buffer.join) }
```

### Handle Errors Gracefully

Prevent callback errors from interrupting the stream:

```ruby
def safe_broadcast(chunk)
  return unless chunk.delta
  ActionCable.server.broadcast("channel", content: chunk.delta)
rescue => e
  Rails.logger.error("Broadcast failed: #{e.message}")
end
```

### Keep on_stream Callbacks Light

Heavy processing should happen in `on_stream_close`:

```ruby
# Good
on_stream { |chunk| @buffer << chunk.delta if chunk.delta }
on_stream_close { expensive_processing(@buffer.join) }

# Avoid - runs for every chunk!
on_stream { |chunk| expensive_processing(chunk.delta) }
```

## Limitations

- **Background jobs**: Streaming doesn't work with `prompt_later` since callbacks require an active agent instance
- **Tool execution**: Providers may pause streaming to execute tools, then resume
- **Provider differences**: Streaming behavior varies by provider—some send metadata chunks, others only send content
- **Structured output**: Not all providers support streaming with structured output schemas

## Next Steps

- [Error Handling](/agents/error_handling) - Handle failures in streaming and generation
- [Callbacks](/agents/callbacks) - Non-streaming lifecycle events
- [Instrumentation](/framework/instrumentation) - Monitor and measure streaming performance
- [Providers](/providers) - Provider-specific streaming documentation
