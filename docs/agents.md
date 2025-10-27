---
title: Agents
---
# Agents

Controllers for AI interactions. Like Rails controllers, agents have actions, callbacks, views, and concerns—but they generate AI responses instead of rendering HTML.

## Quick Example

<<< @/../test/docs/agents_examples_test.rb#quick_example_support_agent{ruby:line-numbers}

Usage:

<<< @/../test/docs/agents_examples_test.rb#quick_example_support_agent_usage{ruby:line-numbers}

## How It Works

The request-response cycle mirrors Rails controllers:

1. **Action called** - `Agent.with(params).action`
2. **Callbacks run** - `before_generation`, `before_prompt`
3. **Context built** - `prompt()` or `embed()` configures messages
4. **View rendered** - ERB template (if exists) renders content
5. **Provider executes** - AI service generates response
6. **Result returned** - Response object with message and metadata

## Building Agents

### Basic Structure

Inherit from `ActiveAgent::Base` (or `ApplicationAgent`) and define actions:

<<< @/../test/docs/agents_examples_test.rb#basic_structure_translation_agent{ruby:line-numbers}

Actions are public instance methods that call `prompt()` or `embed()`.

### Invocation

Call agents using `with()` to pass parameters:

<<< @/../test/docs/agents_examples_test.rb#invocation_with_parameters{ruby:line-numbers}

For prototyping, use direct methods:

<<< @/../test/docs/agents_examples_test.rb#invocation_direct_methods{ruby:line-numbers}

See [Generation](/agents/generation) for complete documentation on execution patterns and response objects.

### Actions Interface

Agents define actions using `prompt()` or `embed()` to configure generation context:

<<< @/../test/docs/agents_examples_test.rb#actions_interface_agent{ruby:line-numbers}

See [Actions](/actions) for complete documentation on messages, tools, structured output, and embeddings.

## Advanced Features

### Using Concerns

Extend agents with concerns to share functionality across multiple agents:

<<< @/../test/docs/agents_examples_test.rb#concerns_research_tools{ruby:line-numbers}

Concerns let you:
- Share tool actions across multiple agents
- Organize complex agents into logical modules
- Reuse common patterns (authentication, logging, data access)
- Test functionality independently

### Callbacks

Hook into the generation lifecycle:

<<< @/../test/docs/agents_examples_test.rb#callbacks_agent{ruby:line-numbers}

See [Callbacks](/agents/callbacks) for complete documentation.

### Streaming

Stream responses in real-time:

<<< @/../test/docs/agents_examples_test.rb#streaming_agent{ruby:line-numbers}

See [Streaming](/agents/streaming) for complete documentation.

## Learn More

**Core Features:**
- [Generation](/agents/generation) - Execution patterns and response objects
- [Instructions](/agents/instructions) - System prompts that guide behavior
- [Callbacks](/agents/callbacks) - Lifecycle hooks and event handling
- [Streaming](/agents/streaming) - Real-time response updates
- [Error Handling](/agents/error-handling) - Retries and graceful degradation

**Related Topics:**
- [Tool Calling](/actions/tool-calling) - Use agent actions as AI-callable tools
- [Structured Output](/actions/structured-output) - Extract typed data with schemas
- [Embeddings](/actions/embeddings) - Vector generation for semantic search
- [Testing](/framework/testing) - Test agents and concerns
- [Instrumentation](/framework/instrumentation) - Monitor with notifications
