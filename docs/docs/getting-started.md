# Getting Started

This guide will help you set up and create your first ActiveAgent application.

## Installation
```bash
# Add this line to your application's Gemfile
gem 'activeagent'
# Add the generation provider gem you want to use, e.g.:
gem 'ruby-openai'
```

Then execute:
```bash
$ bundle install
```
Or install it yourself as:

```bash
$ gem install activeagent
```
### Active Agent install generator
To set up Active Agent in your Rails application, you can use the install generator. This will create the necessary configuration files and directories for Active Agent.

```bash
$ rails generate active_agent:install
```
This command will create the following files and directories:
- `config/active_agent.yml`: The configuration file for Active Agent, where you can specify your generation providers and their settings.
- `app/agents`: The directory where your agent classes will be stored.
- `app/views/agents`: The directory where your agent view templates will be stored.

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

Now, you can interact with your application agent:
```ruby
ApplicationAgent.with(
  instructions: "Help users with their queries.",
  messages: [
    { role: 'user', content: 'What is the weather like today?' }
  ]
).text_prompt.generate_now
```
This code parameterizes the `ApplicationAgent` `with` a set of `params`.

## Configuration
### Generation Provider Configuration
Active Agent supports multiple generation providers, including OpenAI, Anthropic, and Ollama. You can configure these providers in your Rails application using the `config/active_agent.yml` file. This file allows you to specify the API keys, models, and other settings for each provider. This is similar to Active Storage service configurations.

<<< @/../test/dummy/config/active_agent.yml{yaml:line-numbers}

### Configuring custom hosts
You can also set the host and port for the generation provider if needed. For example, if you are using a local instance of Ollama or a cloud provider's hosted instance of OpenAI, you can set the host and port as follows:

```yaml
opnai: &openai
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
<h1>Search for Travel Options</h1>
<p>Enter the location you want to search for:</p>
<form action="<%= search_path %>" method="post">
  <input type="text" name="location" placeholder="Enter location" required>
  <button type="submit">Search</button>
</form> 
```
:::
This code snippet defines the `TravelAgent` class with three actions: `search`, `book`, and `confirm`. Each action can be implemented with specific logic to handle travel-related queries. The `prompt` method is used to render the action's content in the prompt context.


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