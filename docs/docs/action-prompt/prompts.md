# Prompt

The Prompt is the container for runtime context messages and options passed to the generation provider. 

Prompts are responsible for managing the contextual history and providing the necessary information to the generation provider for a meaningful prompt and response cycles.


## Prompt Structure
The Prompt is structured to include the following components:
- **Messages**: An array of messages that represent the contextual information or conversational chat history. Each message includes content, role (user or assistant), and metadata.
- **Message**: The Action Prompt's rendered message object or hash that contains the content and role of the message. The role can be `:user`, `:system`, `:assistant`, or `:tool`, but defaults to `:user`.
- **Actions**:  An array of actions that the agent can perform in response to user input. By default, the prompt will use the agent's action methods, but you can also specify custom actions.
- **Options**: Runtime configuration options that control the generation behavior (e.g., model, temperature, max_tokens). See [Runtime options](actions.md#runtime-options) for details.

## Example Prompt
Prompts are built and rendered in the agent's action methods, typically using the `prompt` method. This is an example of creating a prompt by manually building the context; assigning `actions`, the prompt `message` and context `messages`.

<<< @/../test/action_prompt/prompt_test.rb#support_agent_prompt_initialization{ruby:line-numbers} [support_agent.rb]


## Rendering Prompts
Prompts can be rendered using the `prompt` method inside an Agent's action method, which generates the structured prompt object with the provided context. In this example the `translate` action renders the translate.text.erb template with the provided message and locale parameters, and returns a prompt context that can be used to generate a response.


::: code-group
<<< @/../test/dummy/app/agents/translation_agent.rb{5 ruby:line-numbers} [app/agents/translation_agent.rb]

<<< @/../test/dummy/app/views/translation_agent/translate.text.erb{5 erb:line-numbers} [translate.text.erb]
:::

::: code-group
<<< @/../test/agents/translation_agent_test.rb#translation_agent_render_translate_prompt{ruby} [test/agents/translation_agent_test.rb:6..8]
:::