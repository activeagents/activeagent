---
title: Active Agent
model:
  - title: Prompts (Model)
    link: /actions/prompts
    icon: 💬
    details: The data model containing messages, context, actions (tools), and configuration for AI generation.
view:
  - title: Templates (View)
    link: /framework/action-prompt
    icon: 📄
    details: ERB templates that render prompts and messages in text, HTML, or JSON formats.
controller:
  - title: Agents (Controller)
    link: /framework/agents
    icon: <img src="/activeagent.png" />
    details: Controllers that orchestrate AI interactions with actions, callbacks, streaming, and tool execution.

---
# {{ $frontmatter.title }}

ActiveAgent is the AI framework for Rails. It extends the familiar MVC architecture to AI-powered applications, letting you build intelligent agents using the same patterns you already know—controllers, actions, and views.

## Quick Example

::: code-group

<<< @/../test/dummy/app/agents/overview/support_agent.rb#overview_support_agent {ruby:line-numbers}

<<< @/../test/dummy/app/views/overview/support_agent/help.text.erb {erb}

:::

**Usage:**

<<< @/../test/agents/overview/support_agent_test.rb#overview_example {ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/support-agent-test.rb-test-overview-example.md -->
:::

**That's it.** Agents are controllers. Actions render prompts. Views format messages. If you know Rails, you know ActiveAgent.

## Why ActiveAgent?

ActiveAgent brings **Agent Oriented Programming (AOP)** to Rails. Design applications using modular, reusable agents that integrate seamlessly into your existing codebase. Build complex AI-driven features with the Object-Oriented Ruby patterns you use every day.

**Key benefits:**
- **Familiar patterns** - No new mental models, just Rails doing AI
- **Modular design** - Agents are classes, easy to test and organize
- **Production ready** - Streaming, callbacks, async jobs, structured output
- **Provider agnostic** - OpenAI, Anthropic, Ollama, OpenRouter—unified interface

## MVC Architecture

ActiveAgent extends Rails MVC concepts to AI interactions. Using familiar patterns that made Rails the framework of choice for web applications, ActiveAgent brings the same productivity to AI-powered features.

![ActiveAgent-Controllers](https://github.com/user-attachments/assets/70d90cd1-607b-40ab-9acf-c48cc72af65e)

### Model: Prompt Interface

The **prompt** and **embed** interfaces are your data models for provider interactions. They define how context, messages, actions (tools), and configuration flow through the generation cycle.

Agent actions use these interfaces to structure data for AI providers—just like how controller actions work with model data.

<FeatureCards :cards="$frontmatter.model" />

### View: Message Templates

**Action View templates** optionally render your prompts and instructions. When you call `prompt` or `embed`, ActiveAgent can render ERB templates into formatted content, or you can pass content directly as parameters.

Templates support text, HTML, and JSON formats—giving you full control over how instructions, prompt messages, and embed inputs are structured and sent to AI providers.

<FeatureCards :cards="$frontmatter.view" />

### Controller: Agents

**Agents** are controllers for AI interactions. They orchestrate the generation request-response cycle, manage context through callbacks, coordinate with AI providers, and handle both synchronous and asynchronous generation.

Define actions as public methods. Use callbacks for lifecycle hooks (`before_action`, `after_generation`). Stream responses in real-time with `on_stream`. It's the controller pattern, applied to AI.

<FeatureCards :cards="$frontmatter.controller" />

## How It Works

The request-response cycle mirrors Rails controllers:

1. **Action called** - You call an agent action method with parameters
2. **Context prepared** - Instance variables and callbacks set up the context
3. **View rendered** - ERB template renders into prompt messages via `prompt()` or `embed()` interface
4. **AI generates** - Provider sends prompt to AI service and streams response
5. **Response processed** - Callbacks handle the generated content
6. **Result returned** - Structured data or message content returned to caller

This familiar flow means you can test agents like controllers, organize code like any Rails app, and build AI features using patterns you already understand.

## Next Steps

Ready to build your first agent?

- **[Getting Started](/getting-started)** - Install and create your first agent in 5 minutes
- **[Framework Guide](/framework/agents)** - Deep dive into agents, actions, and prompts
- **[Examples](/examples/data-extraction-agent)** - See real-world agent implementations

Or explore specific features:
- [Tool Calling](/actions/tool-calling) - Let agents execute Ruby methods
- [Structured Output](/agents/structured-output) - Extract data with JSON schemas
- [Streaming](/agents/callbacks#on-stream-callbacks) - Real-time response updates
- [Providers](/framework/providers) - OpenAI, Anthropic, Ollama, and more

