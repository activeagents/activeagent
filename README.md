# Active Agent
Generative AI powered Rails apps

## What is Active Agent?
Active Agent is a framework for interacting with generative AI services. ActiveAgent provides a simple and flexible service adapter interface to support various AI providers.

## How does Active Agent work?
Active Agent provides an interface to define Agents that can load context take prompts then generate content or perform actions. Agents can receive text, image, audio prompts to generate content in the form of text, image, and audio.

### Define Agents
Agents are the core of Active Agent. An agent takes instructions and can perform actions augment responses by providing data used for generation. Agents are defined by a simple Ruby class that inherits from `ActiveAgent::base` located in the `app/agents` directory.



```ruby
# app/agents/inventory_agent.rb
class InventoryAgent < ActiveAgent::Base
  generate_with :openai, model: :gpt4o, temperature: 0.5, max_tokens: 100, instructions: :inventory_operations

  # Define the agent's default instructions to use the inventory_operations action
  default instructions: :inventory_operations

  def inventory_operations
    @organization = Organization.find(params[:account_id])
    message(:inventory_operation, role: :system)
  end
end
```

### Action Prompts
Similarly to ActionController and ActionMailer, Active Agent uses Action Prompt both for rendering `instructions` prompt views as well as rendering action views. Action Prompt `instructions` in the form of a system message.

```ruby
# app/views/agents/inventory_operations.text.erb
  INSTRUCTIONS: You are an inventory manager for <%= @organization.name %>. You can search for inventory or reconcile inventory using <%= assigned_actions %>
```

### What are Actions?
Actions are just Ruby methods so they can do anything app can do already. Actions are commonly used retrieve data or interact with external services. The Actions are called when the agent generates an agent message with 

### How do Agents call Actions?
Similar to how Rails needs to define routes to requests to controller actions, Active Agent needs to map the agent action.

# config/operations.rb
```ruby
Rails.application.agents.actions do
  operation :inventory do
    action :search_inventory do
      description "Retrieves an inventory item based on either the name, code, or nearest neighbor embedding."

      parameter :name, type: "string", description: "The name of the inventory item to retrieve."
      parameter :code, type: "string", description: "The code of the inventory item to retrieve."
      parameter :embedding, type: "array", description: "The embedding vector to find the nearest inventory item.", items: { type: "number" }
    end
  end
end
```

```ruby

#### Actions have consequences (results)

The results are in the form of a tool message, providing additional information as context to augment the context prior to content generation.

#### Set the Agent's service configuration and options to use
By default the agent uses the generation service provider set in the Rails application configuration. 

```ruby
class Application < Rails::Application
  config.active_agent.generation_provider = :openai
end
```

#### Generation service provider configurations are defined in the `config/generation.yml` file
```yaml
openai:
  access_token: <%= Rails.application.credentials.openai_access_token %>
```
# Options


### How can agents be used?
Agents can be used to perform actions 
