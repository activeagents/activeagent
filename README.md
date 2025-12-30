<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://github.com/user-attachments/assets/2bad263a-c09f-40b6-94ba-fff8e346d65d">
  <img alt="activeagents_banner" src="https://github.com/user-attachments/assets/0ebbaa2f-c6bf-4d40-bb77-931015a14be3">
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
```

## Features

- **Agent-Oriented Programming**: Build AI applications using familiar Rails patterns
- **Multiple Provider Support**: Works with OpenAI, Anthropic, Ollama, and more
- **Action-Based Design**: Define agent capabilities through actions
- **View Templates**: Use ERB templates for prompts (text, JSON, HTML)
- **Streaming Support**: Real-time response streaming with ActionCable
- **Tool/Function Calling**: Agents can use tools to interact with external services
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

## Learn More

- [Documentation](https://docs.activeagents.ai)
- [Getting Started Guide](https://docs.activeagents.ai/getting_started)
- [API Reference](https://docs.activeagents.ai/docs/framework)
- [Examples](https://docs.activeagents.ai/docs/agents)

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

## License

Active Agent is released under the [MIT License](LICENSE).
