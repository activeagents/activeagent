# Callbacks

ActiveAgent provides `before_generation`, `after_generation`, and `around_generation` callbacks for the generation lifecycle. These callbacks are also available with the `*_prompting` alias (e.g., `before_prompt`, `after_prompt`, `around_prompt`).

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

## Callback Control

Like Rails controller callbacks, `prepend_*`, `skip_*`, and `append_*` variants are available for all callback types:

```ruby
class ChildAgent < BaseAgent
  prepend_before_prompt :critical_setup  # Runs before inherited callbacks
  skip_after_prompt :log_response        # Remove inherited callback
  append_before_prompt :final_setup      # Same as before_prompt
end
```

## Embedding Callbacks

ActiveAgent provides `before_embed`, `after_embed`, and `around_embed` callbacks for embedding operations. All callback control methods (`prepend_*`, `skip_*`, `append_*`) work the same as prompting callbacks:

<<< @/../test/docs/agents/callbacks_examples_test.rb#embedding_callbacks {ruby:line-numbers}

See [Embeddings](/actions/embeddings) for complete documentation.

## Streaming Callbacks

ActiveAgent provides `on_stream_open`, `on_stream`, and `on_stream_close` callbacks for handling real-time streaming responses:

<<< @/../test/docs/agents/callbacks_examples_test.rb#streaming_callbacks {ruby:line-numbers}

See [Streaming](/agents/streaming) for complete documentation.
