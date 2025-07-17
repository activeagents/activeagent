---
title: Getting Started
---
# {{ $frontmatter.title }}

This guide will help you set up and create your first ActiveAgent application.

## Installation

Use builder to add activeagent to your Gemfile and install:
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
bundle add ruby-openai
# Ollama follows the same API spec as OpenAI, so you can use the same gem.
```

```bash [OpenRouter]
bundle add ruby-openai
# OpenRouter follows the same API spec as OpenAI, so you can use the same gem.
```
:::

Or do it manually by adding the gems to your Gemfile:
```bash
gem 'activeagent'
# Add the generation provider gem you want to use, e.g.:
gem 'ruby-openai'
```

Then install the gems by running:
```bash
bundle install
```
### Active Agent install generator
To set up Active Agent in your Rails application, you can use the install generator. This will create the necessary configuration files and directories for Active Agent.

```bash
rails generate active_agent:install
```
This command will create the following files and directories:
- `config/active_agent.yml`: The configuration file for Active Agent, where you can specify your generation providers and their settings.
- `app/agents`: The directory where your agent classes will be stored.
- `app/views/agent_*`: The directory where your agent prompt/view templates will be stored.

## Usage
Active Agent is designed to work seamlessly with Rails applications. It can be easily integrated into your existing Rails app without any additional configuration. The framework automatically detects the Rails environment and configures itself accordingly.

You can start by defining an `ApplicationAgent` class that inherits from `ActiveAgent::Base`. This class will define the actions and behaviors of your application's base agent. You can then use the `generate_with` method to specify the generation provider for your agent.

```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, instructions: "You are a helpful assistant.",
    model: "gpt-4o-mini",
    temperature: 0.7
end
```
This code snippet sets up the `ApplicationAgent` to use OpenAI as the generation provider. You can replace `:openai` with any other supported provider, such as `:anthropic`, `:google`, or `:ollama`.

Now, you can interact with your application agent using the default `prompt_context` method. This method allows you to provide a context for the agent to generate a response based on the defined actions and behaviors.:

<<< @/../test/agents/application_agent_test.rb#application_agent_prompt_context_message_generation{ruby}

This code parameterizes the `ApplicationAgent` `with` a set of `params`.

## Configuration
### Generation Provider Configuration
Active Agent supports multiple generation providers, including OpenAI, Anthropic, and Ollama. You can configure these providers in your Rails application using the `config/active_agent.yml` file. This file allows you to specify the API keys, models, and other settings for each provider. This is similar to Active Storage service configurations.

<<< @/../test/dummy/config/active_agent.yml{yaml:line-numbers}

### Configuring custom hosts
You can also set the host and port for the generation provider if needed. For example, if you are using a local instance of Ollama or a cloud provider's hosted instance of OpenAI, you can set the host and port as follows:

```yaml
openai: &openai
  service: "OpenAI"
  api_key: <%= Rails.application.credentials.dig(:openai, :api_key) %>
  host: "https://your-azure-openai-resource.openai.azure.com"
```

<!-- ### Initializer
Active Agent is designed to work seamlessly with Rails applications. It can be easily integrated into your existing Rails app without any additional configuration. The framework automatically detects the Rails environment and configures itself accordingly. While its not necessary to include in your Rails app, Active Agent can be configured in the `config/initializers/active_agent.rb` file. You can set default generation providers, models, and other configurations here.

```ruby
ActiveAgent.configure do |config|
  config.default_generation_provider = :openai
  config.default_generation_queue = :agents
  config.default_model = 'gpt-3.5-turbo'
  config.default_temperature = 0.7
end
``` -->

## Your First Agent
You can generate your first agent using the Rails generator. This will create a new agent class in the `app/agents` directory. It will also create a corresponding view template for the agent's actions as well as an Application Agent if you don't already have one. 

```bash
$ rails generate active_agent:agent TravelAgent search book confirm
```
The `ApplicationAgent` is the base class for all agents in your application, similar to how ApplicationController is the base class for all controllers.

```ruby [app/agents/application_agent.rb]
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, instructions: "You are a helpful assistant.",
    model: "gpt-4o-mini",
    temperature: 0.7
  # This is the base class for all agents in your application.
  # You can define common methods and configurations here.
end
```

The `TravelAgent` class will be generated with the specified actions: `search`, `book`, and `confirm`. Each action will be defined as a public instance method in the agent class. The generator will also create a corresponding view template for each action in the `app/views/agents/travel_agent` directory.

The JSON view is used to specify the tool schema for the action it can also be used to allow the agent to return structured data that can be used by other agents or applications. The HTML view is used to render the action's content in a web-friendly format, while the text view is used for plain text responses.


The generated agent will look like this:

::: code-group
```ruby [app/agents/travel_agent.rb]
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
