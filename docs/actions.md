# Actions

Actions are public methods in your agent that define specific AI behaviors. Each action calls `prompt()` to generate text or `embed()` to create vector embeddings.

Think of actions like controller actions in Rails—they define what your agent can do and how it responds to different requests.

## Quick Example

Define an action by creating a method that calls `prompt()`:

<<< @/../test/docs/actions_examples_test.rb#quick_example_summary_agent{ruby:line-numbers}
<<< @/../test/docs/actions_examples_test.rb#quick_example_summary_usage{ruby:line-numbers}

## Action Capabilities

Actions can use these capabilities to build sophisticated AI interactions:

### [Messages](/actions/messages)

Control conversation context with text, images, and documents:

<<< @/../test/docs/actions_examples_test.rb#messages_with_image{ruby:line-numbers}

### [Tools](/actions/tools)

Let AI call Ruby methods during generation:

<<< @/../test/docs/actions_examples_test.rb#tools_weather_agent{ruby:line-numbers}

### [Structured Output](/actions/structured_output)

Enforce JSON responses with schemas:

<<< @/../test/docs/actions_examples_test.rb#structured_output_extract{ruby:line-numbers}

### [Embeddings](/actions/embeddings)

Generate vectors for semantic search:

<<< @/../test/docs/actions_examples_test.rb#embeddings_vectorize{ruby:line-numbers}

## Common Patterns

### Multi-Capability Actions

Combine multiple capabilities in a single action for complex behaviors.

<!-- <<< @/../test/docs/actions_examples_test.rb#multi_capability_action{ruby:line-numbers} -->

Use this pattern when you need the AI to:
- Search for information AND structure the results
- Process data with tools AND validate the output format
- Combine multimodal inputs (text + images) with structured responses

### Chaining Generations

Build multi-step workflows by passing previous responses as conversation history.

<!-- <<< @/../test/docs/actions_examples_test.rb#chaining_generations{ruby:line-numbers} -->

This approach works well for:
- Multi-turn conversations where context matters
- Iterative refinement (generate → critique → improve)
- Workflows where each step builds on previous results

### Multiple Actions Per Agent

Define multiple actions in a single agent for related behaviors.

<!-- <<< @/../test/docs/actions_examples_test.rb#multiple_actions_per_agent{ruby:line-numbers} -->

## Related Documentation

- [Agents](/agents) - Understanding the agent lifecycle and invocation
- [Generation](/agents/generation) - Synchronous and asynchronous execution
- [Callbacks](/agents/callbacks) - Hooks for before/after action execution
