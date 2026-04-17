---
title: Active Agent
description: ActiveAgent extends Rails MVC to AI interactions. Build intelligent agents using familiar patterns—controllers, actions, callbacks, and views.
---
# {{ $frontmatter.title }}

ActiveAgent extends Rails MVC to AI interactions. Build intelligent agents using familiar patterns—controllers, actions, callbacks, and views.

## Quick Example

::: code-group
<<< @/../test/docs/framework_examples_test.rb#quick_example_support_agent{ruby:line-numbers} [support_agent.rb]
<<< @/../test/dummy/app/views/agents/framework_examples_test/quick_example_test/support/instructions.md.erb{md:line-numbers} [support_agent/instructions.md.erb]
:::

**Usage:**

<<< @/../test/docs/framework_examples_test.rb#quick_example_support_agent_usage{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/framework-examples-test.rb-test-quick-example-support-agent-usage.md -->
:::

## Agent Oriented Programming

ActiveAgent applies Agent Oriented Programming (AOP) to Rails—a paradigm where agents are the primary building blocks. Agents combine behavior (instructions), state (context), and capabilities (tools) into autonomous components.

**Programming Paradigm Shift:**

| Concept | Object-Oriented | Agent-Oriented |
|---------|----------------|----------------|
| **Unit** | Object | Agent |
| **Parameters** | message, args, block | prompt, context, tools |
| **Computation** | method, send, return | perform, generate, response |
| **State** | instance variables | prompt context |
| **Flow** | method calls | prompt-response cycles |
| **Constraints** | coded logic | written instructions |

Write instructions instead of algorithms. Define context instead of managing state. Coordinate through prompts instead of method chains.

## Understanding Agents

Agents mirror how users interact with systems—they have identity, behavior, and goals:

| Aspect | User | Agent |
|--------|------|-------|
| **Who** | Persona | Archetype |
| **Behavior** | Stories | Instructions |
| **State** | Scenario | Context |
| **What** | Objective | Goal |
| **How** | Actions | Tools |

When you define an agent, you create a specialized participant that interacts with your application through prompts, maintains conversation context, and uses tools to accomplish objectives.

## Core Architecture

![ActiveAgent-Controllers](https://github.com/user-attachments/assets/70d90cd1-607b-40ab-9acf-c48cc72af65e)

**Three Key Objects:**

- **Agent** (Controller) - Manages lifecycle, defines actions, configures providers
- **Generation** (Request Proxy) - Coordinates execution, holds configuration, provides synchronous/async methods. Created by invocation, it's lazy—execution doesn't start until you call `.prompt_now`, `.embed_now`, or `.prompt_later`.
- **Response** (Result) - Contains messages, metadata, and normalized usage statistics (see **[Usage Statistics](/actions/usage)**). Returned after Generation executes.

**Request-Response Lifecycle:**

1. **Invocation** → Generation object created with parameters
2. **Callbacks** → `before_generation` hooks execute
3. **Action** → Agent method called (optional for direct invocations)
4. **Prompt/Embed** → `prompt()` or `embed()` configures request context
5. **Template** → ERB view renders (if template exists)
6. **Request** → Provider request built with messages, tools, options
7. **Execution** → API called (with streaming/tool execution if configured)
8. **Processing** → Response parsed, messages extracted
9. **Callbacks** → `after_generation` hooks execute
10. **Return** → Response object with message and metadata

**Three Invocation Patterns:**

<<< @/../test/docs/framework_examples_test.rb#invocation_pattern_direct{ruby:line-numbers}
<<< @/../test/docs/framework_examples_test.rb#invocation_pattern_parameterized{ruby:line-numbers}
<<< @/../test/docs/framework_examples_test.rb#invocation_pattern_action_based{ruby:line-numbers}

See [Generation](/agents/generation) for complete execution details.

## MVC Mapping

ActiveAgent maps Rails MVC patterns to AI interactions:

### Model: Prompt Interface

The **prompt** and **embed** interfaces are runtime configuration objects built inside agent actions. Calling `prompt(message: "...", tools: [...])` or `embed(input: "...")` returns a Generation object configured with messages, tools, response_format, temperature, and other parameters that define the AI request.

Use these methods in your action methods to build the request context before execution. See [Messages](/actions/messages) for complete details.

### View: Message Templates

**ERB templates** render instructions, messages, and schemas for AI requests. Templates are optional—you can pass strings or hashes directly.

- **Instructions** - System prompts that guide agent behavior (`.text.erb`, `.md.erb`)
- **Messages** - User/assistant conversation content (`.text.erb`, `.md.erb`, `.html.erb`)
- **Schemas** - JSON response format definitions (`.json`)

See [Instructions](/agents/instructions), [Messages](/actions/messages), and [Structured Output](/actions/structured_output) for template patterns.

### Controller: Agents

**Agents** are controllers with actions (public methods), callbacks (`before_generation`, `after_generation`), and provider configuration (`generate_with`, `embed_with`).

Actions call `prompt()` or `embed()` to configure requests. Callbacks manage context and side effects. Configuration sets defaults for model, temperature, and other options. See [Agents](/agents) for complete patterns.

## Integration Points

ActiveAgent integrates with Rails features and AI capabilities:

- **[Providers](/providers)** - Swap AI services (OpenAI, Anthropic, Ollama, OpenRouter, RubyLLM)
- **[Instructions](/agents/instructions)** - System prompts from templates or strings
- **[Callbacks](/agents/callbacks)** - Lifecycle hooks for context and logging
- **[Tools](/actions/tools)** - Agent methods as AI-callable functions
- **[Structured Output](/actions/structured_output)** - JSON schemas for response format
- **[Streaming](/agents/streaming)** - Real-time response updates
- **[Messages](/actions/messages)** - Multimodal conversation context
- **[Embeddings](/actions/embeddings)** - Vector generation for semantic search

## Next Steps

**Start Here:**
- **[Getting Started](/getting_started)** - Build your first agent (step-by-step tutorial)
- **[Agents](/agents)** - Deep dive into agent patterns and lifecycle
- **[Actions](/actions)** - Define capabilities with messages, tools, and schemas

**Core Features:**
- [Generation](/agents/generation) - Synchronous and asynchronous execution
- [Instructions](/agents/instructions) - System prompts and behavior guidance
- [Messages](/actions/messages) - Conversation context with multimodal support
- [Providers](/providers) - OpenAI, Anthropic, Ollama, OpenRouter, RubyLLM configuration

**Advanced:**
- [Tools](/actions/tools) - AI-callable Ruby methods and MCP integration
- [Structured Output](/actions/structured_output) - JSON schemas and validation
- [Streaming](/agents/streaming) - Real-time response updates
- [Callbacks](/agents/callbacks) - Lifecycle hooks and event handling
- [Testing](/framework/testing) - Test agents with fixtures and VCR

**Rails Integration:**
- [Configuration](/framework/configuration) - Environment-specific settings
- [Instrumentation](/framework/instrumentation) - Logging and monitoring
- [Rails Integration](/framework/rails) - ActionCable, ActiveJob, and more

**Examples:**
- [Data Extraction](/examples/data_extraction_agent) - Parse structured data from documents

