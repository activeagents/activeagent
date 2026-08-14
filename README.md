<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/public/banner-dark.svg">
  <img alt="Active Agent - Build AI in Rails" src="docs/public/banner-light.svg">
</picture>


> *Build AI in Rails*
>
> *Now Agents are Controllers*
>
> *Makes code [TonsOfFun](https://tonsoffun.github.io)!*

# Active Agent
Active Agent provides that missing AI layer in the Rails framework, offering a structured approach to building AI-powered applications through Agent Oriented Programming. **Now Agents are Controllers!** Designing applications using agents allows developers to create modular, reusable components that can be easily integrated into existing systems. This approach promotes code reusability, maintainability, and scalability, making it easier to build complex AI-driven applications with the Object Oriented Ruby code you already use today.

## Documentation
[docs.activeagents.ai](https://docs.activeagents.ai) - The official documentation site for Active Agent.

## Getting Started

### Installation

Use bundler to add activeagent to your Gemfile and install:
```bash
bundle add activeagent
```

That is the framework — agents, providers, generation and telemetry
reporting. The dashboard is a second gem, `actionagent`, added separately
when you want it; see [Dashboard & Dev Console](#dashboard--dev-console).

Add the generation provider gem you want to use:

```bash
# OpenAI
bundle add openai

# Anthropic
bundle add anthropic

# Ollama (uses OpenAI-compatible API)
bundle add openai

# OpenRouter (uses OpenAI-compatible API)
bundle add openai

# RubyLLM (unified API for 15+ providers)
bundle add ruby_llm
```

### Setup

Run the install generator to create the necessary configuration files:

```bash
rails generate active_agent:install
```

This creates:
- `config/active_agent.yml`: Configuration file for generation providers
- `app/agents/application_agent.rb`: Base agent class

### Quick Example

Define an application agent:

```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini"
end
```

Use your agent:

```ruby
response = ApplicationAgent.prompt(message: "Hello, world!").generate_now
puts response.message
# => "Hello! How can I help you today?"
```

### Your First Agent

Generate a new agent:

```bash
rails generate active_agent:agent TravelAgent search book confirm
```

This creates an agent with actions that can be called:

```ruby
class TravelAgent < ApplicationAgent
  def search
    # Your search logic here
    prompt
  end

  def book
    # Your booking logic here
    prompt
  end

  def confirm
    # Your confirmation logic here
    prompt
  end
end
```

## Configuration

Configure generation providers in `config/active_agent.yml`:

```yaml
development:
  openai:
    service: "OpenAI"
    access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
    model: "gpt-4o-mini"

  anthropic:
    service: "Anthropic"
    access_token: <%= Rails.application.credentials.dig(:anthropic, :access_token) %>
    model: "claude-sonnet-4.5"

  ollama:
    service: "Ollama"
    model: "llama3.2"

  ruby_llm:
    service: "RubyLLM"
```

## Dashboard & Dev Console

The dashboard is its own gem, `actionagent`: a mountable Rails engine with
traces and span waterfalls, token usage and per-agent metrics, plus the agent
builder, runs, conversations, evaluations, scorecards and cost estimates — so
you can watch and drive your agents while you build. It ships separately
because its models are Active Record models and it runs agents through
[solid_agent](https://github.com/activeagents/solid_agent) — neither of which
`activeagent` depends on, so an app that only runs agents installs neither.

```bash
bundle add actionagent
rails generate action_agent:install
rails db:migrate
```

```yaml
# config/active_agent.yml
telemetry:
  enabled: true
  local_storage: true
```

The generator mounts the engine at `/activeagents` — open it and every
generation appears as a trace. See
[docs/framework/dashboard.md](docs/framework/dashboard.md) for
authentication, remote ingestion, and multi-tenant mode. The hosted
platform at [activeagents.ai](https://activeagents.ai) runs this same
engine multi-tenant, adding what a hosted product has to have — accounts,
plans, billing, quotas and managed sandboxes; every workspace starts with
a free low-volume trial.

## Features

- **Agent-Oriented Programming**: Build AI applications using familiar Rails patterns
- **Multiple Provider Support**: Works with OpenAI, Anthropic, Ollama, RubyLLM, and more
- **Action-Based Design**: Define agent capabilities through actions
- **View Templates**: Use ERB templates for prompts (text, JSON, HTML)
- **Streaming Support**: Real-time response streaming with ActionCable
- **Tool/Function Calling**: Agents can use tools to interact with external services
- **Agent-as-Tool Delegation**: Hand work to sub-agents with declared schemas, cost/latency budgets, and swappable backends
- **Context Management**: Maintain conversation history across interactions
- **Structured Output**: Define JSON schemas for predictable responses

## Examples

### Data Extraction
Extract structured data from images, PDFs, and text:

```ruby
prompt = DataExtractionAgent.with(
  image_path: Rails.root.join("sales_chart.png")
).parse_content.generate_now
```

### Translation
Translate text between languages:

```ruby
response = TranslationAgent.with(
  message: "Hi, I'm Justin",
  locale: "japanese"
).translate.generate_now
```

### Tool Usage
Agents can use tools to perform actions:

```ruby
# Agent with tool support
prompt = SupportAgent.prompt(message: "Show me a cat")
response = prompt.generate_now
# Response includes tool call results
```

### Delegation
Hand part of a job to a sub-agent, under a declared contract and a budget:

```ruby
class SummarizerAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o-mini"

  delegation :summarize, description: "Condense a document into key points" do
    string :text, required: true, description: "Full document text"
  end

  def summarize(text:) = prompt(message: text)
end

class ResearchAgent < ApplicationAgent
  generate_with :openai, model: "gpt-4o"

  delegate_to SummarizerAgent, budget: { max_calls: 3, timeout: 20 }

  def research(topic:) = prompt(message: "Research #{topic}")
end
```

## Learn More

- [Documentation](https://docs.activeagents.ai)
- [Getting Started Guide](https://docs.activeagents.ai/getting_started)
- [API Reference](https://docs.activeagents.ai/framework)
- [Examples](https://docs.activeagents.ai/agents)

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.MD) for details.

## License

Active Agent is released under the [MIT License](LICENSE).
