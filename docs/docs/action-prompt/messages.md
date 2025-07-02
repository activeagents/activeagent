# Messages
Messages are the core data structure of a prompt's context. Each message represents an interaction as a Message object with a specific role, such as `:user`, `:system`, `:assistant`, or `:tool`.

Message `content` represents the rendered view from an Active Agent action. Messages are used to provide context for the generation process, with the last message's content containing the view rendered by an action prompt and can be used to store additional information about the interaction. The messages are passed to the generation provider as part of the prompt request.

## Message structure
Messages can be structured as a Message object or hash with the following attributes:
- `role`: The role of the message, such as `:user`, `:system`, `:assistant`, or `:tool`.
- `content`: The content of the message, which can be plain text or formatted content.
- `requested_actions`: An array of actions that the agent requested to be performed in response to the message. This is used to handle tool use requests from the agent.


## Instructions as system messages to the agent
A `:system` message is used to provide instructions to the agent. This message is used to set the context for the generation process and can be used to provide additional information about the interaction to the agent. Instructions can include how an agent should use their available actions to achieve a desired outcome or contain embedded ruby to render retrieve data to augment the generation process with contextual information prior to user-agent interactions.

```erb [app/views/agents/instructions.text.erb]
This agent is currently interacting with <%= @user.name %> to find a hotel near their travel destination.
The agent should use the following actions to achieve the desired outcome:
<% actions do |action| %>
  <%= action.name %>: <%= action.description %>
<% end %>

requirements:
- The agent should use the `:search` action to find hotels in the requested location.
- The agent should use the `:book` action to book a hotel for the user.
- The agent should use the `:confirm` action to confirm the booking with the user.
```

## User's send :user messages to the agent
A `:user` message is used to represent the user's input to the agent. These messages are commonly seen as plain text chat messages, but should be thought of as an Action View that could be of any type you choose to support, just like Action Mailer can send 'plain/text' or 'html/text' emails, Action Prompt render formatted messages to the agents.

## Agent's send :assistant messages to the user
An `:assistant` message is used to represent the agent's response to the user. These messages are also often seen as justin plain text chat messages, but again should be thought of as an Action View template that could be of any type you choose to support. This enables the agent to render formatted messages to the user, such as HTML or TXT with interpolated instance variables and embedded ruby. The agent can use these messages to provide additional information or context to the user, and can also include links or other interactive elements.

## The system responds to agent requested actions with :tool messages
Agent performed actions result in `:tool` message. These messages are used to represent the response to a tool call made by the agent. This message is used to provide additional information about the tool call, such as the name of the tool and any arguments that were passed to the tool. The system can use this message to provide a response message containing the result of the tool call and can also include links or other interactive elements.