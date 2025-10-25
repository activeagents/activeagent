# Messages
Messages are the core data structure of a prompt's context. Each message represents an interaction as a Message object with a specific role, such as `:user`, `:system`, `:assistant`, or `:tool`.

Message `content` represents the rendered view from an Active Agent action. Messages are used to provide context for the generation process, with the last message's content containing the view rendered by an action prompt and can be used to store additional information about the interaction. The messages are passed to the provider as part of the prompt request.

## Message structure
Messages can be structured as a Message object or hash with the following attributes:
- `role`: The role of the message, such as `:user`, `:system`, `:assistant`, or `:tool`.
- `content`: The content of the message, which can be plain text or formatted content.
- `requested_actions`: An array of actions that the agent requested to be performed in response to the message. This is used to handle tool use requests from the agent.

```ruby
# Messages include system, user, assistant, and tool messages
assert response.prompt.messages.size >= 5

# Group messages by role
system_messages = response.prompt.messages.select { |m| m.role == :system }
user_messages = response.prompt.messages.select { |m| m.role == :user }
assistant_messages = response.prompt.messages.select { |m| m.role == :assistant }
tool_messages = response.prompt.messages.select { |m| m.role == :tool }
```


## Instructions as system messages to the agent
A `:system` message is used to provide instructions to the agent. This message is used to set the context for the generation process and can be used to provide additional information about the interaction to the agent. Instructions can include how an agent should use their available tool actions to achieve a desired outcome as well as render embedded ruby representations of retrieved data to augment the generation process with contextual information prior to user-agent interactions.

```erb
This agent is currently interacting with <%= @user.name %> to find a hotel near their travel destination.
The agent should use the following actions to achieve the desired outcome:

<% controller.action_schemas.each do |action| %>
  <%= action["function"]["name"] %>: <%= action["function"]["description"] %>
<% end %>

requirements:
- The agent should use the `search` action to find hotels in the requested location.
- The agent should use the `book` action to book a hotel for the user.
- The agent should use the `confirm` action to confirm the booking with the user.
```

### Agent instructions
Agent's can use `generate_with` to define instructions for the agent.

```ruby
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini"
  embed_with :openai, model: "text-embedding-3-small"
end
```

Agent's can also use implicit instructions by defining an `instructions` view in the agent's view directory.

```erb
# app/views/application_agent/instructions.text.erb
# (Instructions can be defined here as ERB template)
```



## User's send :user messages to the agent
A `:user` message is used to represent the user's input to the agent. These messages are commonly seen as plain text chat messages, but should be thought of as an Action View that could be of any type you choose to support, just like Action Mailer can send 'plain/text' or 'html/text' emails, Action Prompt render formatted messages to the agents.

## Agent's send :assistant messages to the user
An `:assistant` message is used to represent the agent's response to the user. These messages are also often seen as plain text chat messages, but again should be thought of as an Action View template that could be of any type you choose to support. This enables the agent to render formatted messages to the user, such as HTML or TXT with interpolated instance variables and embedded ruby. The agent can use these messages to provide additional information or context to the user, and can also include links or other interactive elements.

### Messages with Requested Actions

```ruby
# Assistant messages with requested_actions indicate tool calls
assistant_with_actions = assistant_messages.find { |m| m.requested_actions&.any? }
assert assistant_with_actions, "Should have assistant message with requested actions"
```

## The system responds to agent requested actions with :tool messages
Agent performed actions result in `:tool` message. These messages are used to represent the response to a tool call made by the agent. This message is used to provide additional information about the tool call, such as the name of the tool and any arguments that were passed to the tool. The system can use this message to provide a response message containing the result of the tool call and can also include links or other interactive elements.

```ruby
# Tool messages contain the results of tool calls
assert_includes tool_messages.first.content, "https://cataas.com/cat/"
```

## Building Message Context

Messages form the conversation history that provides context for the agent. [Learn how messages flow through generation →](/agents/generation)

```ruby
# The response message is the last message in the context
assert_equal response.message, response.prompt.messages.last
```
