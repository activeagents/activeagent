# Generation Provider

Generation Providers are the backbone of the Active Agent framework, allowing seamless integration with various AI services. They provide a consistent interface for prompting and generating responses, making it easy to switch between different providers without changing the core logic of your application.

::: code-group

```ruby [OpenAI]
class ApplicationAgent < ActiveAgent::Base
  generate_with :openai
end
```

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

<<< @/../test/dummy/app/agents/open_router_agent.rb#snippet{ruby:line-numbers} [openrouter]

<<< @/../test/dummy/app/agents/ollama_agent.rb#snippet{ruby:line-numbers} [ollama]

:::

## Key Features
- **Unified Interface**: All generation providers implement a common interface, making it easy to switch between them.
- **Customizable**: You can create your own generation providers to suit your specific needs.
- **Built-in Providers**: Active Agent comes with built-in providers for popular AI services like OpenAI and Anthropic.
- **Easy Integration**: Integrate with your existing Rails application with minimal setup.
- **Asynchronous Support**: Generation Jobs use Active Job to handle long-running background task processing with ease.
- **Error Handling**: Built-in error handling and retry mechanisms for robust applications.
- **Logging and Monitoring**: Track the performance and usage of your generation providers.
- **Testing Support**: Mock and stub generation providers for unit testing.


