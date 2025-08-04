---
title: Getting Started
---
# {{ $frontmatter.title }}

This guide will help you set up and create your first ActiveAgent application.

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

<<< @/../test/dummy/app/agents/application_agent.rb {ruby}

This sets up the `ApplicationAgent` to use OpenAI as the generation provider. You can replace `:openai` with any other supported provider, such as `:anthropic`, `:google`, or `:ollama`.

Now, you can interact with your application agent using the default `prompt_context` method. This method allows you to provide a context for the agent to generate a response based on the defined actions and behaviors:

<<< @/../test/agents/application_agent_test.rb#application_agent_prompt_context_message_generation{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/test-it-renders-a-prompt-with-an-plain-text-message-and-generates-a-response-test-it-renders-a-prompt-with-an-plain-text-message-and-generates-a-response.md -->
:::

This code parameterizes the `ApplicationAgent` `with` a set of `params`.

## Configuration
### Generation Provider Configuration
Active Agent supports multiple generation providers, including OpenAI, Anthropic, and Ollama. You can configure these providers in your Rails application using the `config/active_agent.yml` file. This file allows you to specify the API keys, models, and other settings for each provider. This is similar to Active Storage service configurations.

<<< @/../test/dummy/config/active_agent.yml{yaml:line-numbers}

### Configuring custom hosts
You can also set the host and port for the generation provider if needed. For example, if you are using a local instance of Ollama or a cloud provider's hosted instance of OpenAI, you can set the host in your configuration file as shown in the example above.

## Your First Agent
You can generate your first agent using the Rails generator. This will create a new agent class in the `app/agents` directory. It will also create a corresponding view template for the agent's actions as well as an Application Agent if you don't already have one. 

```bash
$ rails generate active_agent:agent TravelAgent search book confirm
```
The `ApplicationAgent` is the base class for all agents in your application, similar to how ApplicationController is the base class for all controllers.

The generator will create:
- An agent class with the specified actions (`search`, `book`, and `confirm`)
- View templates for each action in `app/views/travel_agent/`
- An `ApplicationAgent` base class if one doesn't exist

<<< @/../test/dummy/app/agents/travel_agent.rb {ruby}

Agent action methods are used for building Prompt context objects with Message content from rendered Action Views.

## Action Prompts
### Instruction messages
### Prompt messages

Each action is defined as a public instance method that can call `prompt` to build context objects that are used to generate responses. The views define:
- **JSON views**: Tool schemas for function calling or output schemas for structured responses
- **HTML views**: Web-friendly formatted responses  
- **Text views**: Plain text responses
