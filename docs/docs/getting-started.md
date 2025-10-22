---
title: Getting Started
---
# {{ $frontmatter.title }}

This guide will help you set up and create your first ActiveAgent application.

## Prerequisites

Before using Active Agent, ensure you have:
- Ruby 3.0 or higher
- Rails 7.0 or higher
- API keys for your chosen generation provider(s)

You'll configure your API keys in the `config/active_agent.yml` file after installation.

## Installation

Use bundler to add activeagent to your Gemfile and install:

```bash
bundle add activeagent
```

Add the generation provider gem you want to use:

::: code-group

```bash [OpenAI]
bundle add ruby-openai
```

```bash [Anthropic]
bundle add ruby-anthropic
```

```bash [Ollama]
# Ollama follows the same API spec as OpenAI, so you can use the same gem.
bundle add ruby-openai
```

```bash [OpenRouter]
bundle add ruby-openai
# OpenRouter follows the same API spec as OpenAI, so you can use the same gem.
```

:::

Then install the gems by running:

```bash
bundle install
```

### Active Agent Install Generator

To set up Active Agent in your Rails application, run the install generator. This creates the necessary configuration files and directories:

```bash
rails generate active_agent:install
```

This command creates:
- `config/active_agent.yml`: Configuration file for generation providers and their settings
- `app/agents/`: Directory for your agent classes
- `app/views/layouts/agent.text.erb`: Layout file for agent prompt/view templates
- `app/views/agent_*/`: Directories for your agent prompt/view templates

## Usage

Active Agent is designed to work seamlessly with Rails applications. The framework automatically detects the Rails environment and configures itself accordingly.

### Creating Your Application Agent

Define an `ApplicationAgent` class that inherits from `ActiveAgent::Base`. This serves as the base class for all agents in your application, similar to how `ApplicationController` works:

<<< @/../test/dummy/app/agents/application_agent.rb {ruby}

This sets up the `ApplicationAgent` to use OpenAI as the generation provider. You can replace `:openai` with any other supported provider, such as `:anthropic` or `:ollama`.

### Using Agent.prompt(...) for Simple Interactions

Active Agent provides a direct `Agent.prompt(...)` method for simple message-based interactions. This method doesn't require a view template—you can pass messages directly as parameters:

<<< @/../test/agents/application_agent_test.rb#application_agent_prompt_context_message_generation{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/application-agent-test.rb-test-it-renders-a-prompt-with-an-plain-text-message-and-generates-a-response.md -->
:::

This example:
1. Calls `ApplicationAgent.prompt(message: message)` to create a prompt object with the message
2. Generates a response synchronously with `generate_now`

The `Agent.prompt(...)` method is ideal for simple conversational interactions where you don't need custom view templates or complex message formatting.

## Configuration

### Generation Provider Configuration

Active Agent supports multiple generation providers, including OpenAI, Anthropic, and Ollama. Configure these providers in `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml{yaml:line-numbers}

**Configuration options:**

- `service`: The provider name (`"OpenAI"`, `"Anthropic"`, `"Ollama"`, etc.)
- `access_token`: Your API key (can be hardcoded or use environment variables)
- `model`: The model to use (e.g., `"gpt-4o-mini"`, `"claude-3-5-sonnet"`)
- `temperature`: Controls randomness in responses (0.0 to 1.0)

**Using Environment Variables:**

For security, use environment variables instead of hardcoding API keys:

```yaml
openai:
  service: "OpenAI"
  access_token: <%= ENV['OPENAI_API_KEY'] %>
  model: "gpt-4o-mini"
  temperature: 0.7
```

**Using Rails Credentials (Optional):**

Alternatively, you can use Rails credentials for API key management:

```yaml
openai:
  service: "OpenAI"
  access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
  model: "gpt-4o-mini"
  temperature: 0.7
```

### Configuring Custom Hosts

You can set custom hosts for generation providers if needed. This is useful for:
- Running a local instance of Ollama
- Using a proxy or custom endpoint
- Connecting to enterprise or self-hosted AI services

Example configuration for a local Ollama instance:

```yaml
ollama:
  service: "Ollama"
  uri_base: "http://localhost:11434"
  model: "gemma3:latest"
```

## Your First Agent

### Generating an Agent with the Rails Generator

Create a custom agent using the Rails generator. This creates a new agent class with custom actions and corresponding view templates:

```bash
rails generate active_agent:agent TravelAgent search book confirm
```

The generator creates:
- `app/agents/travel_agent.rb`: Agent class with the specified actions
- `app/views/travel_agent/*.erb`: View templates for each action
- `app/agents/application_agent.rb`: Base agent class (if it doesn't exist)

### Understanding Agent Actions

Here's the generated `TravelAgent` class:

<<< @/../test/dummy/app/agents/travel_agent.rb {ruby}

**Key concepts:**
- Each action is a public instance method
- Actions call `prompt` to build a prompt context object
- The `prompt` method can specify options like `content_type` (`:text`, `:html`, `:json`)
- Actions can set instance variables (`@departure`, `@destination`) that are available in view templates

### Action View Templates

Each action has a corresponding view template that renders the message content. For example, the `search` action uses `app/views/travel_agent/search.text.erb`:

<<< @/../test/dummy/app/views/travel_agent/search.text.erb {erb}

The template has access to:
- Instance variables set in the action (`@departure`, `@destination`, `@results`)
- Rails helpers and partials
- The `controller` object for accessing agent methods

### Using Your Custom Agent

Call your agent's actions using the same parameterization pattern:

```ruby
# Call the search action with parameters
prompt = TravelAgent.with(
  departure: "New York",
  destination: "San Francisco",
  results: [
    { airline: "United", price: 299, departure: "10:00 AM" },
    { airline: "Delta", price: 325, departure: "2:00 PM" }
  ]
).search

# Generate a response
response = prompt.generate_now
```

The agent will render the `search.text.erb` template with your data and generate an AI response based on the formatted message.

## Understanding Action Prompts

Action Prompts are the core of how agents generate contextual AI responses. When you call an action method, it builds a prompt context object that contains the formatted message, configuration, and metadata needed for generation.

### The `prompt` Method

Inside an action method, call `prompt` to build the prompt context. The `prompt` method accepts several options:

```ruby
def search
  @departure = params[:departure]
  @destination = params[:destination]
  @results = params[:results] || []

  prompt(
    content_type: :text,           # Format: :text, :html, :json
    message: "Custom message",      # Override rendered template
    messages: [],                   # Include conversation history
    instructions: "Be helpful",     # System instructions
    temperature: 0.7,               # Override provider temperature
    max_tokens: 1000                # Token limit for response
  )
end
```

### Two Ways to Build Prompts

**1. Using `Agent.prompt(...)` (direct, simple)**
- Direct class method that doesn't require a view template
- Pass messages directly via parameters
- Ideal for simple conversational interactions
- Example: `ApplicationAgent.prompt(message: "Hello")`

**2. Using custom actions with templates (template-based, flexible)**
- Define your own action methods
- Create view templates (`.text.erb`, `.html.erb`, `.json.erb`)
- Access instance variables in templates
- Full control over message formatting
- Example: `TravelAgent.with(departure: "NYC").search`

### System Instructions

Agents can provide system-level instructions to guide AI behavior. Instructions can be defined in three ways:

**1. In `generate_with` configuration:**

```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai,
    model: "gpt-4o-mini",
    instructions: "You are a helpful assistant."
end
```

**2. In an `instructions.text.erb` template:**

Create `app/views/travel_agent/instructions.text.erb`:

<<< @/../test/dummy/app/views/travel_agent/instructions.text.erb {erb}

**3. Inline in the `prompt` call:**

```ruby
def search
  prompt instructions: "Be concise and friendly when presenting flight options"
end
```

### View Template Formats

Templates can be rendered in different formats to support various use cases:

- **Text views** (`.text.erb`): Plain text messages for conversational interactions
- **HTML views** (`.html.erb`): Formatted content for web-friendly display
- **JSON views** (`.json.erb`): [Tool schemas for function calling](/docs/action-prompt/tools) or [output schemas for structured responses](/docs/active-agent/structured-output)

## Next Steps

Now that you understand the basics, explore these topics:

- **[Action Prompts](/docs/action-prompt/prompts)**: Deep dive into prompt contexts, messages, and actions
- **[Tool Calling](/docs/action-prompt/tools)**: Enable agents to call functions and execute actions
- **[Structured Output](/docs/active-agent/structured-output)**: Parse AI responses into structured data
- **[Callbacks](/docs/active-agent/callbacks)**: Hook into the generation lifecycle
- **[Streaming](/docs/active-agent/streaming)**: Stream responses in real-time
