# Generation Provider

Generation Providers are the backbone of the Active Agent framework, allowing seamless integration with various AI services. They provide a consistent interface for prompting and generating responses, making it easy to switch between different providers without changing the core logic of your application.

## Available Providers
You can use the following generation providers with Active Agent:
::: code-group

<<< @/../test/dummy/app/agents/open_ai_agent.rb#snippet{ruby:line-numbers} [OpenAI]

```ruby [Anthropic]
class ApplicationAgent < ActiveAgent::Base
  generate_with :anthropic
end
```

```ruby [Google]
class ApplicationAgent < ActiveAgent::Base
  generate_with :google
end
```

<<< @/../test/dummy/app/agents/open_router_agent.rb#snippet{ruby:line-numbers} [OpenRouter]

<<< @/../test/dummy/app/agents/ollama_agent.rb#snippet{ruby:line-numbers} [Ollama]
:::

## Response
Generation providers handle the request-response cycle for generating responses based on the provided prompts. They process the prompt context, including messages, actions, and parameters, and return the generated response.

### Response Object
The `ActiveAgent::GenerationProvider::Response` class encapsulates the result of a generation request, providing access to both the processed response and debugging information.

#### Attributes

- **`message`** - The generated response message from the AI provider
- **`prompt`** - The complete prompt object used for generation, including updated context, messages, and parameters
- **`raw_response`** - The unprocessed response data from the AI provider, useful for debugging and accessing provider-specific metadata

#### Example Usage
::: code-group

<<<@/../test/dummy/app/agents/application_agent.rb#application_agent_text_prompt_message_generation{ruby:line-numbers} [application_agent.rb]

```ruby [irb]{ruby:line-numbers}
# Access the response message
puts response.message

# Inspect the prompt that was sent
puts response.prompt.inspect

# Access the messages in the prompt
puts response.prompt.messages.inspect

# Debug with raw response data
puts response.raw_response.inspect
```
:::
The response object ensures you have full visibility into both the input prompt context and the raw provider response, making it easy to debug generation issues or access provider-specific response metadata.
