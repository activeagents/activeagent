# Actions

Actions are callable functions that agents can execute to perform specific tasks.

## Defining Actions

## Parameters

## Responses
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