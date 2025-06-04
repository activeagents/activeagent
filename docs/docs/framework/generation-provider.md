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
