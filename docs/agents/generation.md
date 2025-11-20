---
title: Generation
description: Execute AI generations synchronously with prompt_now or asynchronously with prompt_later using ActiveAgent's generation methods.
---
# {{ $frontmatter.title }}

Execute AI generations synchronously or asynchronously using ActiveAgent's generation methods.

## Synchronous

Execute immediately and return the response:

<<< @/../test/docs/agents/generation_examples_test.rb#synchronous_generation_basic{ruby:line-numbers}

Use `prompt_now` (alias: `generate_now`) for generations or `embed_now` for embeddings.

## Asynchronous

Queue for background execution using Active Job:

<<< @/../test/docs/agents/generation_examples_test.rb#asynchronous_generation_basic{ruby:line-numbers}

<<< @/../test/docs/agents/generation_examples_test.rb#asynchronous_generation_options{ruby:line-numbers}

Use `prompt_later` (alias: `generate_later`) for generations or `embed_later` for embeddings. Background jobs run through `ActiveAgent::GenerationJob` and respect your Active Job configuration.

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

## Prompt Previews

Preview the final prompt without executing generation, including rendered templates and merged parameters:

<<< @/../test/docs/agents/generation_examples_test.rb#prompt_preview_basic{ruby:line-numbers}

The preview returns markdown-formatted output with YAML frontmatter:

::: details Markdown Preview
<!-- @include: @/parts/examples/generation-examples-test.rb-test-preview-prompt-before-execution.md -->
:::

::: tip
Since previews include all parameters, messages, instructions, and tool definitions, hashing the preview can be used to build cache keys.
:::

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

# Usage statistics (see /actions/usage for details)
response.usage             # Normalized usage object across all providers
response.usage.input_tokens
response.usage.output_tokens
response.usage.total_tokens
```

For embeddings:

<<< @/../test/docs/agents/generation_examples_test.rb#response_objects_embedding{ruby:line-numbers}

```ruby
response.data         # Collection of Embedding Datum

response.raw_request  # The most recent request in provider format
response.raw_response # The most recent response in provider format
response.context      # The original context that was sent

# Usage statistics
response.usage             # Normalized usage object
response.usage.input_tokens
```

## Next Steps

- [Agents](/agents) - Understanding the full agent lifecycle
- [Actions](/actions) - Define what your agents can do
- [Usage Statistics](/actions/usage) - Track token consumption and costs
- [Messages](/actions/messages) - Work with multimodal content
- [Tools](/actions/tools) - Enable function calling capabilities
- [Streaming](/agents/streaming) - Stream responses in real-time
- [Callbacks](/agents/callbacks) - Hook into generation lifecycle
- [Error Handling](/agents/error_handling) - Handle failures gracefully
- [Configuration](/framework/configuration) - Configure generation behavior
- [Testing](/framework/testing) - Test generation patterns
