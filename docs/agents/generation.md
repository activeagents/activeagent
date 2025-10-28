---
title: Generation
description: Execute AI generations synchronously with generate_now or asynchronously with generate_later using ActiveAgent's generation methods.
---
# {{ $frontmatter.title }}

Execute AI generations synchronously or asynchronously using ActiveAgent's generation methods.

## Synchronous

Execute immediately and return the response:

<<< @/../test/docs/agents/generation_examples_test.rb#synchronous_generation_basic{ruby:line-numbers}

Use `generate_now` (alias: `prompt_now`) for generations or `embed_now` for embeddings.

## Asynchronous

Queue for background execution using Active Job:

<<< @/../test/docs/agents/generation_examples_test.rb#asynchronous_generation_basic{ruby:line-numbers}

<<< @/../test/docs/agents/generation_examples_test.rb#asynchronous_generation_options{ruby:line-numbers}

Use `generate_later` (alias: `prompt_later`) for generations or `embed_later` for embeddings. Background jobs run through `ActiveAgent::GenerationJob` and respect your Active Job configuration.

Configure queue name and adapter:

<<< @/../test/docs/agents/generation_examples_test.rb#background_job_configuration{ruby:line-numbers}

Jobs use your Active Job adapter (Sidekiq, Resque, etc.).

## Interfaces

### Direct Generation

Generate without defining action methods:

<<< @/../test/docs/agents/generation_examples_test.rb#direct_generation_basic{ruby:line-numbers}

### Parameterized Generation

Pass parameters to action methods:

<<< @/../test/docs/agents/generation_examples_test.rb#parameterized_generation_agent{ruby:line-numbers}

<<< @/../test/docs/agents/generation_examples_test.rb#parameterized_generation_usage{ruby:line-numbers}

### Action-Based Generation

Define reusable actions:

<<< @/../test/docs/agents/generation_examples_test.rb#action_based_generation_agent{ruby:line-numbers}

<<< @/../test/docs/agents/generation_examples_test.rb#action_based_generation_usage{ruby:line-numbers}

## Inspecting Before Execution

Access prompt properties before generating:

<<< @/../test/docs/agents/generation_examples_test.rb#inspecting_before_execution{ruby:line-numbers}

This is useful for debugging, testing, or conditional execution.

## Response Objects

All generations return response objects:

<<< @/../test/docs/agents/generation_examples_test.rb#response_objects_prompt{ruby:line-numbers}

```ruby
response.message           # Most Recent Message
response.messages          # Full Message Stack
response.parsed_json       # Extracted JSON, if Parsable

response.raw_request       # The most recent request in provider format
response.raw_response      # The most recent response in provider format
response.context           # The original context that was sent

# Usage statistics (when available from provider)
response.prompt_tokens     # Input tokens used
response.completion_tokens # Output tokens used
response.total_tokens      # Total tokens used
```

For embeddings:

<<< @/../test/docs/agents/generation_examples_test.rb#response_objects_embedding{ruby:line-numbers}

```ruby
response.data         # Collection of Embedding Datum

response.raw_request  # The most recent request in provider format
response.raw_response # The most recent response in provider format
response.context      # The original context that was sent

# Usage statistics (when available from provider)
response.prompt_tokens
```

## Next Steps

- [Agents](/agents) - Understanding the full agent lifecycle
- [Actions](/actions) - Define what your agents can do
- [Messages](/actions/messages) - Work with multimodal content
- [Tools](/actions/tools) - Enable function calling capabilities
- [Streaming](/agents/streaming) - Stream responses in real-time
- [Callbacks](/agents/callbacks) - Hook into generation lifecycle
- [Error Handling](/agents/error_handling) - Handle failures gracefully
- [Configuration](/framework/configuration) - Configure generation behavior
- [Testing](/framework/testing) - Test generation patterns
