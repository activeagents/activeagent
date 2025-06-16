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
::: code-group
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

```html
<%# app/views/travel_agent/search.html.erb %>
<div>
  <h1>Search Results</h1>
  <p><%= @prompt.message %></p>
  <ul>
    <% @prompt.results.each do |result| %>
      <li><%= result.title %> - <%= result.price %></li>
    <% end %>
  </ul>
</div>
```

```erb [json]
{
  "message": "<%= @prompt.message %>",
  "results": <%= @prompt.results.to_json %>
}
```

```erb [text]
<%# app/views/travel_agent/confirm.text.erb %>
Your booking has been confirmed!
Booking ID: <%= @prompt.booking_id %>
Thank you for choosing our service.
```
:::

## Concepts
### User-Agent interactions
We're not talking about HTTP User Agents here, but rather the interactions between the user and the AI agent. The user interacts with the agent through a series of prompt context messages and actions that are defined in the agent class. These actions can be used to retrieve data, create custom views, handle user input, and manage the flow of data between different components of your application.

Agents are conceptually similar to a user in the sense that they have a persona, behavior, and state. They can perform actions and have objectives, just like a user. The following table illustrates the similarities between the user and the AI agent:
|          |       User |  Agent       |
| :------: | ---------: | :----------- |
| Who      |    Persona | Archetype    |
| Behavior |    Stories | Instructions |
| State    |   Scenario | Context      |
| What     |  Objective | Goal         |
| How      |    Actions | Tools        |

### Agent Oriented Programming (AOP)
Agent Oriented Programming (AOP) is a programming paradigm that focuses on the use of agents as a primary building block of applications. It allows developers to create modular, reusable components that can be easily integrated into existing systems. AOP promotes code reusability, maintainability, and scalability, making it easier to build complex AI-driven applications.
|             |                    OOP |  AOP                           |
| :---------: | ---------------------: | :----------------------------- |
| unit        |                 Object | Agent                          |
| params      |   message, args, block | prompt, context, tools         |
| computation |   method, send, return | perform, generate, response    |
| state       |      instance variables| prompt context                 |
| flow        |           method calls | prompt and response cycles     |
| constraints |            coded logic | written instructions           |
