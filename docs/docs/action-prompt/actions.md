# Actions
Actions are the tools that agents can use to interact with tools through text and JSON views or interact with users through text and HTML views. Actions can be used are used to render `:assistant` messages back to a user or `:tool` messages to provide the result of an action back to the agent.
Actions are functionally tools that agents can use to perform specific tasks.

## Features
- Automatically included in the agent's context.
- Schema generation for tool definitions.
- Seamless integration with prompts.
- Support for multiple action content types (e.g., text, JSON, HTML).
- Customizable actions with dynamic view templates for Retrieval Augmented Generation (RAG).

## Defining Actions
By default, public instance methods defined in the agent class are considered actions. You can also define actions in a separate concern module and include them in your agent class.

```ruby [app/agents/travel_agent.rb]
class TravelAgent < ActiveAgent::Agent
  def search
    Place.search(params[:location])
  end

  def book
    Place.book(hotel_id: params[:hotel_id], user_id: params[:user_id])
  end

  def confirm
    Place.confirm(params[:booking_id])
  end
end
```

## Parameters

### How responses are handled
1. The agent receives a response from the generation provider, which includes the generated content and any actions that need to be performed.
2. The agent processes the response 
3. If there are no `requested_actions` then response is sent back to the user.
4. If the response includes actions, then agent executes them and updates the context accordingly.
5. If the resulting context `requested_actions` includes `reiterate`, then context is updated with the new messages, actions, and parameters, and the cycle continues.


### Respond to User
1. You provide the model with a prompt or conversation history, along with a set of tools.
2. Based on the context, the model may decide to call a tool.
3. If a tool is called, it will execute and return data.
4. This data can then be passed to a view for rendering to the user.
### Respond to Agent
1. The user interacts with UI elements connected to Action Controllers that call Agent's to generate content or the user enters a message in the chat UI.
2. The message is sent to the controller action
3. In your controller action, the language model generates tool calls during the `generate_*` call.
4. All tool calls are persistent in context and renderable to the User
5. Tools are executed using their process action method and their results are forwarded to the context.
6. You can return the tool result from the `after_generate` callback.
7. Tool calls that require user interactions can be displayed in the UI. The tool calls and results are available as tool invocation parts in the parts property of the last assistant message.
8. When the user interaction is done, render tool result can be used to add the tool result to the chat or UI view element.
9. When there are tool calls in the last assistant message and all tool results are available, this flow is reiterated.
## Error Handling

## Tool Definitions

## Examples