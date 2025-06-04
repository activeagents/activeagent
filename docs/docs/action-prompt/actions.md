# Actions
Actions are the tools that agents can use to interact with tools through text and JSON views or interact with users through text and HTML views. Actions can be used are used to render `:assistant` messages back to a user or `:tool` messages to provide the result of an action back to the agent.
Actions are functionally tools that agents can use to perform specific tasks.

## Features
- Automatically included in the agent's context.
- Schema generation for tool definitions.
- Seamless integration with prompts.
- Support for multiple action content types (e.g., text, JSON, HTML).
- Customizable actions with dynamic view templates for Retrieval Augmented Generation (RAG).
- Prompt method to render the action's content in the prompt.

## Defining Actions
By default, public instance methods defined in the agent class are considered actions. You can also define actions in a separate concern module and include them in your agent class.

```ruby [app/agents/travel_agent.rb]
class TravelAgent < ActiveAgent::Agent
  def search
    Place.search(params[:location])
    prompt
  end

  def book
    Place.book(hotel_id: params[:hotel_id], user_id: params[:user_id])
    prompt
  end

  def confirm
    Place.confirm(params[:booking_id])
    prompt
  end
end
```

## Parameters
Agent Actions can accept parameters, which are passed as a hash to the action method. You can access parameters using the `params` method, just like Controller or Mailer Actions.

## Prompt Method
The `prompt` method is used to render the action's content in the prompt. The `prompt()` method is similar to `mail()` in Action Mailer or `render()` in Action Controller, it allows you to specify the content type and view template for the action's response.

```ruby [app/agents/travel_agent.rb]
class TravelAgent < ActiveAgent::Agent
  def search
    Place.search(params[:location])
    prompt(content_type: :text, view: 'search_results')
  end

  def book
    Place.book(hotel_id: params[:hotel_id], user_id: params[:user_id])
    prompt(content_type: :json, view: 'booking_confirmation')
  end

  def confirm
    Place.confirm(params[:booking_id])
    prompt(content_type: :html, view: 'confirmation_page')
  end
end
```
### Runtime options
- `content_type`: Specifies the type of content to be rendered (e.g., `:text`, `:json`, `:html`).
- `view`: Specifies the view template to be used for rendering the action's response. This can be a string representing the view file name or a symbol representing a predefined view.
- `stream`: If set to `true`, the response will be streamed to the user in real-time. This is useful for long-running actions or when you want to provide immediate feedback to the user.
- `options`: Additional options that can be passed to the generation provider, such as model parameters or generation settings.
  
## How Actions are Invoked
1. The agent receives a request from the user, which may include a message or an action to be performed.
2. The agent processes the request and determines if an action needs to be invoked.
3. If an action is invoked, the agent calls the corresponding method and passes the parameters to it.
4. The action method executes the logic defined in the agent and may interact with tools or perform other tasks.
5. The action method returns a response, which can be a rendered view, JSON data, or any other content type specified in the `prompt` method.
6. The agent updates the context with the action's result and prepares the response to be sent back to the user.

## How responses are handled
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