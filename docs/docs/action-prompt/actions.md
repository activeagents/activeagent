# Actions
Active Agent Actions render views, just like Action Controller or Action Mailer. Similar to Action Mailer that renders Mail objects with Messages, Active Agent renders Prompt objects with Messages. 

## Prompt 
The `prompt` method is used to render the action's content as a message in a prompt. The `prompt` method is similar to `mail` in Action Mailer or `render` in Action Controller, it allows you to specify the content type and view template for the action's response.

These Prompt objects contain the context Messages and available Actions. These actions are the interface that agents can use to interact with tools through text and JSON views or interact with users through text and HTML views. 

Actions can be used to render Prompt objects with `:assistant` Messages back to a user or `:tool` Messages to provide the result of an action back to the Agent. 

## Defining Actions
You can define actions in your agent class that can be used to interact with the agent. 

::: code-group
<<< @/../test/dummy/app/agents/translation_agent.rb{ruby:line-numbers} [translation_agent.rb]
<<< @/../test/dummy/app/views/translation_agent/translate.json.jbuilder{ruby:line-numbers} [translate.json.jbuilder]
<<< @/../test/dummy/app/views/translation_agent/translate.text.erb{erb:line-numbers} [translate.text.erb]
:::



## Set up instructions

You can configure instructions in several ways when using `generate_with`. Here are the supported options:

#### 1. Use the default instructions template
If you don’t pass anything for instructions, it will automatically try to use the default instructions template: `instructions.text.erb`

::: code-group
<<< @/../test/dummy/app/agents/scoped_agents/translation_agent_with_default_instructions_template.rb{ruby:line-numbers} [translation_agent_with_default_instructions_template.rb]
<<< @/../test/dummy/app/views/scoped_agents/translation_agent_with_default_instructions_template/instructions.text.erb{erb:line-numbers} [instructions.text.erb]
:::

#### 2. Use a custom instructions template (global or per action)
You can provide custom instructions using a template. This can be done in two ways:
  * **Globally**, by setting an instructions template for the whole agent.
  * **Per action**, by specifying a different template for a specific prompt call.
To do this, pass a `Hash` with a `template` key to the `instructions` option:

::: code-group
<<< @/../test/dummy/app/agents/scoped_agents/translation_agent_with_custom_instructions_template.rb{ruby:line-numbers} [translation_agent_with_custom_instructions_template.rb]
<<< @/../test/dummy/app/views/scoped_agents/translation_agent_with_custom_instructions_template/custom_instructions.text.erb{erb:line-numbers} [custom_instructions.text.erb]
<<< @/../test/dummy/app/views/scoped_agents/translation_agent_with_custom_instructions_template/overridden_instructions.text.erb{erb:line-numbers} [overridden_instructions.text.erb]
:::

#### 3. Use plain text instructions
You can also directly pass a string of instructions

::: code-group
<<< @/../test/dummy/app/agents/translation_agent.rb{ruby:line-numbers} [translation_agent.rb]
:::

## Call to Actions
These actions can be invoked by the agent to perform specific tasks and receive the results or in your Rails app's controllers, models, or jobs to prompt the agent for generation with a templated prompt message. By default, public instance methods defined in the agent class are included in the context as available actions. You can also define actions in a separate concern module and include them in your agent class.

::: code-group
<<< @/../test/agents/translation_agent_test.rb#translation_agent_render_translate_prompt{ruby} [test/agents/translation_agent_test.rb:6..8]
:::

## Action params
Agent Actions can accept parameters, which are passed as a hash to the action method. You pass arguments to agent's using the `with` method and access parameters using the `params` method, just like Mailer Actions.

<<< @/../test/agents/actions_examples_test.rb#actions_with_parameters{ruby:line-numbers}

## Using Actions to prompt the Agent with a templated message
You can call these actions directly to render a prompt to the agent directly to generate the requested object.

::: code-group
<<< @/../test/agents/translation_agent_test.rb#translation_agent_translate_prompt_generation{ruby} [test/agents/translation_agent_test.rb:15..16]
:::

## Using Agents to call Actions
You can also provide an Agent with a prompt context that includes actions and messages. The agent can then use these actions to perform tasks and generate responses based on the provided context.

<<< @/../test/agents/actions_examples_test.rb#actions_prompt_context_generation{ruby:line-numbers}

In this example, the `TravelAgent` will use the provided message as context to determine which actions to use during generation. The agent can then call the `search` action to find hotels, `book` action to initialize a hotel booking, or `confirm` action to finalize a booking, as needed based on the prompt context.

### Content Types

Actions can render different content types based on their purpose:

<<< @/../test/agents/actions_examples_test.rb#actions_content_types{ruby:line-numbers}

The `prompt` takes the following options:
- `content_type`: Specifies the type of content to be rendered (e.g., `:text`, `:json`, `:html`).
- `message`: The `message.content` to be displayed in the prompt.
- `messages`: An array of messages objects to be included in the prompt's context.
- `template_name`: Specifies the name of the template to be used for rendering the action's response.
- `instructions`: Additional guidance for the prompt generation. This can be:
  * A string with custom instructions (e.g., "Help the user find a hotel");
  * A hash referencing a template (e.g., { template: :custom_template });

<<< @/../test/dummy/app/agents/travel_agent.rb {ruby}

## Action View Templates & Partials
While partials can be used in the JSON views the action's json view should primarily define the tool schema, then secondarily define the tool's output using a partial to render results of the tool call all in a single JSON action view template. Use the JSON action views for tool schema definitions and results, and use the text or HTML action views for rendering the action's response to the user.

### Runtime options
- `content_type`: Specifies the type of content to be rendered (e.g., `:text`, `:json`, `:html`).
- `view`: Specifies the view template to be used for rendering the action's response. This can be a string representing the view file name or a symbol representing a predefined view.
- `stream`: If set to `true`, the response will be streamed to the user in real-time. This is useful for long-running actions or when you want to provide immediate feedback to the user.
- `options`: Additional options that can be passed to the generation provider, such as model parameters or generation settings.
  
## How Agents use Actions
1. The agent receives a request from the user, which may include a message or an action to be performed.
2. The agent processes the request and determines if an action needs to be invoked.
3. If an action is invoked, the agent calls the corresponding method and passes the parameters to it.
4. The action method executes the logic defined in the agent and may interact with tools or perform other tasks.
5. The action method returns a response, which can be a rendered view, JSON data, or any other content type specified in the `prompt` method.
6. The agent updates the context with the action's result and prepares the response to be sent back to the user.

## How Agents handle responses
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

## Features
- Automatically included in the agent's context as tools.
- Schema rendering for tool definitions.
- Support for multiple Action View template content types (e.g., text, JSON, HTML).
- Customizable actions with dynamic view templates for Retrieval Augmented Generation (RAG).
- Prompt method to render the action's content in the prompt context.
  
## Tool Definitions
Tool schema definitions are also view templates that can be rendered to the agent. They are used to define the structure and parameters of the tools that the agent can use. Tool definitions are typically defined in JSON format and can include properties, required fields, and descriptions. They can be represented in various formats, such as jbuilder, JSON, or ERB templates, to provide a structured way to define the tools available to the agent.

<<< @/../test/dummy/app/views/support_agent/get_cat_image.json.erb{erb:line-numbers} [get_cat_image.json.erb]