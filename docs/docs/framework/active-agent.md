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


::: code-group
<<< @/../test/dummy/app/agents/translation_agent.rb{ruby:line-numbers} [translation_agent.rb]
<<< @/../test/dummy/app/views/translation_agent/translate.json.jbuilder{ruby:line-numbers} [translate.json.jbuilder]
<<< @/../test/dummy/app/views/translation_agent/translate.text.erb{erb:line-numbers} [translate.text.erb]
:::

## Key Features
- **Prompt management**: Handle prompt-generation request-response cycles with actions that render templated prompts with messages, context, and params.
- **[Action methods](/docs/action-prompt/actions)**: Define public methods that become callable tools or functions for the Agent to perform actions that can render prompts to the agent or generative views to the user.
- **[Queued Generation](/docs/active-agent/queued-generation)**: Manage asynchronous prompt generation and response cycles with Active Job, allowing for efficient processing of requests.
- **[Callbacks](/docs/active-agent/callbacks)**: Use `before_action`, `after_action`, `before_generation`, `after_generation` callbacks to manage prompt context and handle generated responses.
- **[Streaming](/docs/active-agent/callbacks#on-stream-callbacks)**: Support real-time updates with the `on_stream` callback to the user interface based on agent interactions.
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

