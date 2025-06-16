# Prompt

The Prompt is the core data model that contains the runtime context messages, variables, and configuration for the prompt. It is responsible for managing the contextual history and providing the necessary information to the generation provider for a meaningful prompt and response cycles.


## Prompt Structure
The Prompt is structured to include the following components:
- **Messages**: An array of messages that represent the conversation history. Each message includes content, role (user or assistant), and metadata.
- **Message**: A message object or hash that contains the content and role of the message. The role can be `:user`, `:system`, `:assistant`, or `:tool`, but defaults to `:user`.
- **Actions**:  An array of actions that the agent can perform in response to user input. By default, the prompt will use the agent's action methods, but you can also specify custom actions.

## Example Prompt
```ruby
## Prompt are built and rendered in the agent's action methods, typically using the `prompt` method. This is an example of manually creating a prompt and assigning `actions`, `message` and `messages`.
prompt = ActiveAgent::ActionPrompt::Prompt.new(
  actions: SupportAgent.new.action_schemas, 
  message: "I need help with my account.",
  messages: [
    { content: "Hello, how can I assist you today?", role: "assistant" },
  ]
)
```