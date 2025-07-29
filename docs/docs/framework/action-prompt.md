---
title: Action Prompt
---
# {{ $frontmatter.title }}

Action Prompt provides a structured way to manage prompt contexts and handle responses with callbacks as well as perform actions that render messages using Action View templates. 

ActiveAgent::Base implements a `prompt_context` action which by default will render a prompt context object with message text content, that can contain messages, actions, and params. This action doesn't need a template as long as a Message or String are passed into the `message: params[:message]`

<<< @/../test/agents/application_agent_test.rb#application_agent_prompt_context_message_generation {ruby:line-numbers}

Similarly to Action Mailers that render mail messages that are delivered through configured delivery methods, Action Prompt integrates with Generation Providers through the generation module. This allows for dynamic content generation and the ability to use Rails helpers and partials within the prompt templates as well as rendering content from performed actions. Empowering developers with a powerful way to create interactive and engaging user experiences.

## Prompt-generation Request-Response Cycle
The prompt-generation cycle is similar to the request-response cycle of Action Controller and is at the core of the Active Agent framework. It involves the following steps:
1. **Prompt Context**: The Prompt object is created with the necessary context, including messages, actions, and parameters.
2. **Generation Request**: The agent sends a request to the generation provider with the prompt context, including the messages and actions.
3. **Generation Response**: The generation provider processes the request and returns a response, which is then passed back to the agent.
4. **Response Handling**: The agent processes the response which can be sent back to the user or used for further processing.
5. **Action Execution**: If the response includes actions, the agent executes them and updates the context accordingly.
6. **Updated Context**: The context is updated with the new messages, actions, and parameters, and the cycle continues.

## Prompt Context
Action Prompt renders prompt context objects that represent the contextual data and runtime parameters for the generation process. Prompt context objects contain messages, actions, and params that are passed in the request to the agent's generation provider. The context object is responsible for managing the contextual history and providing the necessary information for prompt and response cycles.
