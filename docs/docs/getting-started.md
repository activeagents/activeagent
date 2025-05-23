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

## Basic Usage