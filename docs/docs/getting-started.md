# Getting Started

This guide will help you set up and create your first ActiveAgent application.

## Installation
```bash
# Add this line to your application's Gemfile
gem 'activeagent'
```

Then execute:
```bash
$ bundle install
```
Or install it yourself as:

```bash
$ gem install activeagent
```

### Generation Provider Configuration
Active Agent supports multiple generation providers, including OpenAI, Anthropic, and Ollama. You can configure these providers in your Rails application using the `config/active_agent.yml` file. This file allows you to specify the API keys, models, and other settings for each provider. This is similar to Active Storage service configurations.

```yml
development:
  openai:
    service: "OpenAI"
    api_key: <%= Rails.application.credentials.dig(:openai, :api_key) %>
    model: "gpt-4o-mini"
    temperature: 0.7
  open_router:
    service: "OpenRouter"
    api_key: <%= Rails.application.credentials.dig(:open_router, :api_key) %>
    model: "qwen/qwen3-30b-a3b:free"
    temperature: 0.7
  ollama:
    service: "Ollama"
    api_key: ""
    model: "gemma3:latest"
    temperature: 0.7
```

### Initializer
Active Agent is designed to work seamlessly with Rails applications. It can be easily integrated into your existing Rails app without any additional configuration. The framework automatically detects the Rails environment and configures itself accordingly. While its not necessary to include in your Rails app, Active Agent can be configured in the `config/initializers/active_agent.rb` file. You can set default generation providers, models, and other configurations here.

```ruby
ActiveAgent.configure do |config|
  config.default_generation_provider = :openai
  config.default_generation_queue = :agents
  config.default_model = 'gpt-3.5-turbo'
  config.default_temperature = 0.7
end
```

## Your First Agent
You can generate your first agent using the Rails generator. This will create a new agent class in the `app/agents` directory. It will also create a corresponding view template for the agent's actions as well as an Application Agent if you don't already have one. 

```bash
$ rails generate active_agent:agent TravelAgent search book confirm
```
The `ApplicationAgent` is the base class for all agents in your application, similar to how ApplicationController is the base class for all controllers.

```ruby [app/agents/application_agent.rb]
class ApplicationAgent < ActiveAgent::Base
  # This is the base class for all agents in your application.
  # You can define common methods and configurations here.
end
```
The `TravelAgent` class will be generated with the specified actions: `search`, `book`, and `confirm`. Each action will be defined as a public instance method in the agent class. The generator will also create a corresponding view template for each action in the `app/views/agents/travel_agent` directory.

The JSON view is used to specify the tool schema for the action it can also be used to allow the agent to return structured data that can be used by other agents or applications. The HTML view is used to render the action's content in a web-friendly format, while the text view is used for plain text responses.

```json [app/views/agents/travel_agent/search.json.erb]
{
  "tool": {
    "name": "search",
    "description": "Search for travel options",
    "parameters": {
      "type": "object",
      "properties": {
        "location": {
          "type": "string",
          "description": "The location to search for travel options"
        }
      },
      "required": ["location"]
    }
  }
}
```

```erb [app/views/agents/travel_agent/search.html.erb]

```

The generated agent will look like this:

```ruby
class TravelAgent < ActiveAgent::Base
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

## Basic Usage
When interfacing with an agent, you typically start by providing a prompt context to the agent. This context can include instructions, user messages, and any other relevant information that the agent needs to generate a response. The agent will then process this context and return a response based on its defined actions.

```ruby
TravelAgent.with(
  instructions: "Help users with travel-related queries, using the search, book, and confirm actions.",
  messages: [
    { role: 'user', content: 'I need a hotel in Paris' }
  ]
).generate_later
```
This code snippet initializes the `TravelAgent` with a set of instructions and a user message. The agent will then process this context and generate a response based on its defined actions.