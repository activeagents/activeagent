---
title: Active Agent
model:
  - title: Context (Model)
    link: /docs/action-prompt/prompts
    icon: 📝
    details: Prompt Context is the core data model that contains the runtime context, messages, variables, and configuration for the prompt.
view:
  - title: Prompt (View)
    link: /docs/framework/action-prompt
    icon: 🖼️
    details: Action View templates are responsible for rendering the prompts to agents and UI to users.
controller:
  - title: Agents (Controller)
    link: /docs/framework/active-agent
    icon: <img src="/activeagent.png" />
    details: Agents are Controllers with a common Generation API with enhanced memory and tooling.

---
# Active Agent

Agents are Controllers that act as the core of the Active Agent framework. Active Agent manages AI-driven interactions, prompts, actions, and generative responses.

## Key Features
- **Prompt management**: Handle prompt-generation request-response cycles with structured prompts, messages, actions, and context.
- **Action methods**: Define public methods that become callable tools or functions for the Agent.
- **Generation providers**: Integrate with AI services like OpenAI or Anthropic.

## Example
```ruby
class TravelAgent < ApplicationAgent
  def search
    prompt(message: params[:message], content_type: :html)
  end

  def book
    prompt(message: params[:message], content_type: :json)
  end

  def confirm
    prompt(message: params[:message], content_type: :text)
  end
end
```

