# Agents

Agents are Controllers that act as the core of the Active Agent framework. They manage AI-driven interactions, prompts, actions, and generative responses.

## Key Features
- **Prompt Management**: Handle prompt-response cycles with structured prompts, messages, actions, and context.
- **Action Execution**: Define action methods that become callable tools or functions for the Agent.
- **Generation Providers**: Integrate with AI services like OpenAI or Anthropic.

## Example
```ruby
class TravelAgent < ActiveAgent::Base
  def search
    prompt()
  end
end
```

