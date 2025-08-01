# Generation Provider

Generation Providers are the backbone of the Active Agent framework, allowing seamless integration with various AI services. They provide a consistent interface for prompting and generating responses, making it easy to switch between different providers without changing the core logic of your application.

## Available Providers
You can use the following generation providers with Active Agent:
::: code-group

<<< @/../test/dummy/app/agents/open_ai_agent.rb#snippet{ruby:line-numbers} [OpenAI]

<<< @/../test/dummy/app/agents/anthropic_agent.rb {ruby} [Anthropic]

<<< @/../test/dummy/app/agents/google_agent.rb {ruby} [Google]

<<< @/../test/dummy/app/agents/open_router_agent.rb#snippet{ruby:line-numbers} [OpenRouter]

<<< @/../test/dummy/app/agents/ollama_agent.rb#snippet{ruby:line-numbers} [Ollama]

<<< @/../test/dummy/app/agents/deepseek_agent.rb {ruby} [Deepseek]
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

<<< @/../test/generation_provider_examples_test.rb#generation_response_usage{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/generation_response_usage_example-response_object_usage.md -->
:::
The response object ensures you have full visibility into both the input prompt context and the raw provider response, making it easy to debug generation issues or access provider-specific response metadata.

## Provider Configuration

You can configure generation providers with custom settings:

### Model and Temperature Configuration

<<< @/../test/generation_provider_examples_test.rb#anthropic_provider_example{ruby:line-numbers}

<<< @/../test/generation_provider_examples_test.rb#google_provider_example{ruby:line-numbers}

### Custom Host Configuration

For Azure OpenAI or other custom endpoints:

<<< @/../test/generation_provider_examples_test.rb#custom_host_configuration{ruby:line-numbers}

## Ruby LLM Provider

ActiveAgent integrates with [Ruby LLM](https://github.com/crmne/ruby_llm) to provide multi-backend support for various AI providers. This allows you to use providers that aren't directly implemented in ActiveAgent.

### Automatic Provider Detection

Providers not directly supported by ActiveAgent will automatically use Ruby LLM:

<<< @/../test/agents/ruby_llm_provider_test.rb#ruby_llm_auto_detection{ruby:line-numbers}

### Explicit Ruby LLM Usage

You can explicitly specify Ruby LLM as the generation driver:

<<< @/../test/agents/ruby_llm_provider_test.rb#ruby_llm_explicit_driver{ruby:line-numbers}

### Custom Configuration with Ruby LLM

<<< @/../test/agents/ruby_llm_provider_test.rb#ruby_llm_custom_config{ruby:line-numbers}

### Supported Ruby LLM Providers

Ruby LLM supports the following providers:
- OpenAI
- Anthropic
- Google (Gemini)
- Deepseek
- Groq
- Mistral
- Perplexity
- Together
- OpenRouter

Each provider requires appropriate API keys to be set either in configuration or environment variables.
