# Agents

Agents are the core of the Active Agent framework. They act as controllers for AI-driven interactions, managing prompts, actions, and responses.

## Key Features
- **Prompt Management**: Handle structured prompts with messages, actions, and context.
- **Action Execution**: Define and execute callable tools or functions.
- **Generation Providers**: Integrate with AI services like OpenAI or Anthropic.

## Example
```ruby
class TravelAgent < ActiveAgent::Base
  def search
    prompt { |format| format.text { render plain: "Searching for travel options" } }
  end
end
```

## Features
- Automatically included in the agent's context.
- Schema generation for tool definitions.
- Seamless integration with prompts.

