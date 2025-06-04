# Generation
Prompt Generation is a core feature of the Active Agent framework, enabling the creation of dynamic and interactive user experiences through AI-driven prompts and responses. It allows developers to define how agents generate content, interact with users, and perform actions based on the generated responses.

## Key Features
- **Dynamic Prompt Generation**: Create prompts that adapt based on user input and context.
- **Action Integration**: Seamlessly integrate actions into prompts, allowing agents to perform tasks and return results.
- **Context Management**: Maintain context across interactions, enabling agents to remember previous conversations and actions.
- **Customizable Templates**: Use templates to define the structure and appearance of prompts, making it easy to create consistent and engaging user experiences.
- **Support for Multiple Content Types**: Render prompts in various formats, including text, JSON, and HTML, to suit different use cases.
## Prompt Generation Request-Response Cycle
The prompt generation cycle is similar to the request-response cycle of Action Controller and is at the core of the Active Agent framework. It involves the following steps:
1. **Prompt Context**: The Prompt object is created with the necessary context, including messages, actions, and parameters.
2. **Generation Request**: The agent sends a request to the generation provider with the prompt context, including the messages and actions.
3. **Generation Response**: The generation provider processes the request and returns a response, which is then passed back to the agent.
4. **Response Handling**: The agent processes the response, which can be sent back to the user or used for further processing.
5. **Action Execution**: If the response includes actions, the agent executes them and updates the context accordingly.
6. **Updated Context**: The context is updated with the new messages, actions, and parameters, and the cycle continues.
## Prompt Context
Action Prompt renders prompt context objects that represent the contextual data and runtime parameters for the generation process. Prompt context objects contain messages, actions, and params that are passed in the request to the agent's generation provider. The context object is responsible for managing the contextual history and providing the necessary information for prompt and response cycles.
## Example Prompt Generation

```ruby
response = ApplicationAgent.text_prompt(message: 'This is a new context').generate_now
```

### Generation with Context
Loading a context from an existing prompt context:
```ruby
response = ApplicationAgent.text_prompt(messages: response.prompt.messages).generate_now
```

## Queued Generation
Generation can be performed using Active Job to handle the prompt-generation and perform actions asynchronously. This is the most common way to handle generation in production applications, as it allows for better scalability and responsiveness.

To perform queued generation, you can use the `generate_later` method, which enqueues the generation job to be processed later by Active Job. 
```ruby
response = ApplicationAgent.text_prompt(message: params[:message], messages: response.prompt.messages).generate_later
```

