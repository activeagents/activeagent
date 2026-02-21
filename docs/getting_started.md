---
title: Getting Started
description: Build AI agents with Rails in minutes. Learn how to install, configure, and create your first agent.
---
# {{ $frontmatter.title }}

Build AI agents with Rails in minutes. This guide covers installation, configuration, and creating your first agent.

## Prerequisites

- Ruby 3.0+
- Rails 7.0+
- API key for your chosen provider (OpenAI, Anthropic, Ollama, or RubyLLM)

## Installation

Add activeagent and your provider gem:

```bash
bundle add activeagent
```

Add your provider gem:

::: code-group

```bash [OpenAI]
bundle add openai
```

```bash [Anthropic]
bundle add anthropic
```

```bash [Ollama]
bundle add openai  # Ollama uses OpenAI-compatible API
```

```bash [OpenRouter]
bundle add openai  # OpenRouter uses OpenAI-compatible API
```

```bash [RubyLLM]
bundle add ruby_llm  # Unified API for 15+ providers
```

:::

Run the install generator:

```bash
rails generate active_agent:install
```

This creates:
- `config/active_agent.yml` - Provider configuration
- `app/agents/application_agent.rb` - Base agent class

## Configuration

Configure your provider in `config/active_agent.yml`:

```yaml
openai:
  service: "OpenAI"
  access_token: <%= ENV['OPENAI_API_KEY'] %>
  model: "gpt-4o-mini"
```

See **[Configuration](/framework/configuration)** for environment-specific settings, multiple providers, and advanced options.

## Quick Start

Test your setup with direct generation:

```ruby
response = ApplicationAgent.prompt(message: "Hello, world!").generate_now
puts response.message
# => "Hello! How can I help you today?"
```

This is perfect for testing your setup or quick experiments. For production apps, define custom agents with actions (shown below).

## Your First Agent

### Generate an Agent

Create an agent with the Rails generator:

```bash
rails generate active_agent:agent SupportAgent help
```

This creates:
- `app/agents/support_agent.rb` - Agent class with actions
- `app/views/agents/support/help.text.erb` - View template

### Define the Agent

The generated agent defines actions as public methods:

```ruby
class SupportAgent < ApplicationAgent
  def help
    @message = params[:message]
    @user_id = params[:user_id]
    prompt
  end
end
```

Create a message template at `app/views/agents/support/help.text.erb`:

```erb
Help Request from User <%= @user_id %>
=====================================

The user needs assistance with: <%= @message %>

Please provide a helpful response.
```

### Use Your Agent

```ruby
response = SupportAgent.with(
  user_id: 123,
  message: "How do I reset my password?"
).help.generate_now

puts response.message
# => "To reset your password, follow these steps..."
```

## Core Concepts

### Three Invocation Patterns

ActiveAgent supports three ways to invoke agents:

**1. Direct (testing/prototyping):**
```ruby
ApplicationAgent.prompt(message: "Hello").generate_now
```

**2. Parameterized (pass data to actions):**
```ruby
SupportAgent.with(user_id: 123, message: "Need help").help.generate_now
```

**3. Action-based (production pattern):**
```ruby
class SupportAgent < ApplicationAgent
  def help
    prompt(message: "User #{params[:user_id]} needs: #{params[:message]}")
  end
end
```

### Instructions

Guide agent behavior with system instructions. Define them three ways:

**In `generate_with` configuration:**
```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, instructions: "You are a helpful assistant."
end
```

**In an `instructions.text` template:**
```erb
You are a support agent helping users with their questions.
Be concise, friendly, and provide clear solutions.
```

**Inline in the action:**
```ruby
def help
  prompt(instructions: "Answer the user's question clearly and briefly")
end
```

See **[Instructions](/agents/instructions)** for complete details.

### Execution

Generate responses synchronously or asynchronously:

```ruby
# Synchronous
response = agent.generate_now
puts response.message

# Asynchronous (via Active Job)
agent.generate_later(wait: 5.minutes)
```

See **[Generation](/agents/generation)** for background jobs, callbacks, and response objects.

## Next Steps

**Core Features:**
- **[Agents](/agents)** - Actions, callbacks, concerns, streaming
- **[Messages](/actions/messages)** - Images, documents, conversation history
- **[Tools](/actions/tools)** - Function calling and MCP integration
- **[Structured Output](/actions/structured_output)** - Parse JSON with schemas
- **[Embeddings](/actions/embeddings)** - Vector generation for semantic search
- **[Providers](/providers)** - OpenAI, Anthropic, Ollama, OpenRouter, RubyLLM

**Framework:**
- **[Configuration](/framework/configuration)** - Environment settings, precedence
- **[Rails Integration](/framework/rails)** - Generators, helpers, conventions
- **[Retries](/framework/retries)** - Error handling and retry strategies
- **[Instrumentation](/framework/instrumentation)** - Logging and monitoring
- **[Testing](/framework/testing)** - Test your agents with fixtures and VCR
