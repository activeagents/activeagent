# Callbacks

ActiveAgent provides `before_generation`, `after_generation`, and `around_generation` callbacks for the generation lifecycle. These callbacks are also available with the `*_prompting` alias (e.g., `before_prompting`, `after_prompting`, `around_prompting`).

## Before Generation

Runs before the generation executes. Use for setup, loading context, or validation:

<<< @/../test/docs/agents/callbacks_examples_test.rb#before_generation {ruby:line-numbers}

## After Generation

Runs after generation completes. Use for logging, caching, or post-processing:

<<< @/../test/docs/agents/callbacks_examples_test.rb#after_generation {ruby:line-numbers}

After callbacks are skipped if the callback chain is terminated with `throw :abort`.

## Around Generation

Wraps the entire generation process. Use for timing, transactions, or wrapping operations:

<<< @/../test/docs/agents/callbacks_examples_test.rb#around_generation {ruby:line-numbers}

## Multiple and Conditional Callbacks

Register multiple callbacks and apply them conditionally with `:if` and `:unless`. Callbacks execute in registration order (before/around) or reverse order (after):

<<< @/../test/docs/agents/callbacks_examples_test.rb#multiple_conditional_callbacks {ruby:line-numbers}

Execution order: `load_context`, `check_rate_limit` (if enabled), [generation], `log_response`

## Embedding Callbacks

ActiveAgent provides `before_embedding`, `after_embedding`, and `around_embedding` callbacks for embedding operations. Behavior is identical to generation callbacks:

<<< @/../test/docs/agents/callbacks_examples_test.rb#embedding_callbacks {ruby:line-numbers}

See [Embeddings](/actions/embeddings) for complete documentation.

## Streaming Callbacks

ActiveAgent provides `on_stream_open`, `on_stream`, and `on_stream_close` callbacks for handling real-time streaming responses:

<<< @/../test/docs/agents/callbacks_examples_test.rb#streaming_callbacks {ruby:line-numbers}

See [Streaming](/agents/streaming) for complete documentation.
