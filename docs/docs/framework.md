---
title: Framework Overview
cards:
  - title: Agents
    link: /docs/framework/active-agent
    icon: <img src="/activeagent.png" />
    details: Agents are Controllers with a common Generation API with enhanced memory and tooling.

---
# Framework Overview

ActiveAgent provides a structured approach to building AI-powered applications.

## Core Concepts
<FeatureCards :cards="$frontmatter.cards" />
- **Agents** are abstract controllers that handles AI interactions using a specified generation provider.
- **Prompts** are the core data model that contains the runtime context, messages, variables, and configuration for the prompt.
- **Actions**: are the agent's interface to perform tasks and render Action Views for templated agent prompts and user interfaces.
- **Generation Provider**: A generation provider is the backend interface to AI services that enable agents to generate content, embeddings, and request actions.

## Architecture
Active Agent is built around a few core components that work together to provide a seamless experience for developers and users. Using familiar concepts from Rails that made it the MVC framework of choice for web applications, Active Agent extends these concepts to the world of AI and generative models.

### Prompts are the context Models
The Prompt is the core data model that contains the runtime context messages, variables, and configuration for the prompt. It is responsible for managing the contextual history and providing the necessary information for prompt and response cycles.

### Actions Prompts and Views

### Agents are the Controllers
Agents are the core of the Active Agent framework and control the prompt and response cycle. Agents are controllers for AI-driven interactions, managing prompts, actions, and responses. Agents are responsible for managing context, handling user input, generating content, and interacting with generation providers.

### Queued Generation Jobs
Active Agent provides a built-in job queue for generating content asynchronously. This allows for efficient processing of requests and ensures that the application remains responsive even during heavy load. Scale it just like you would with any other Rails application with Active Jobs.

### Generation Providers are the AI Service Backends
Generation providers are the backend interfaces to AI services that enable agents to generate content, embeddings, and request actions. They provide a common interface for different AI providers, allowing developers to easily switch between them without changing the core application logic. Using `generate_with` method, you can easily switch between different providers, configurations, instructions, models, and other parameters to optimize the agentic processes.

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

## Configuration
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


## Usage