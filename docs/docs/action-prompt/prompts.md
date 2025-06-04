# Prompt

The Prompt is the core data model that contains the runtime context messages, variables, and configuration for the prompt. It is responsible for managing the contextual history and providing the necessary information to the generation provider for a meaningful prompt and response cycles.
## Example Prompt
```ruby
prompt = ActiveAgent::Prompt.new(
  messages: [
    { content: "Hello, how can I assist you today?", role: "assistant" },
    { content: "I need help with my account.", role: "user" }
  ],
  variables: { user_id: 123, session_id: "abc-123" },
  context: { user_preferences: { language: "en", timezone: "UTC" } },
  configuration: {
    generation_provider: :openai,
    response_format: :text
  }
)
```

## Prompt Structure
The Prompt is structured to include the following components:
- **Messages**: An array of messages that represent the conversation history. Each message includes content, role (user or assistant), and metadata.
- **Variables**: Actions use instance variables to store dynamic data that can be referenced in the prompt view templates. These variables can be used to pass user-specific data or session information to the generation provider.
- **Context**: A hash that provides additional context for the prompt, such as user-specific data or session information. This context can be used to tailor the prompt to the specific needs of the user or application.
- **Configuration**: Settings that define how the prompt should be processed, such as the generation provider to use, response format, and any additional options required by the provider.

## Usage