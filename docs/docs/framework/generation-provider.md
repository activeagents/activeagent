# Generation Provider

Generation Providers are the backbone of the Active Agent framework, allowing seamless integration with various AI services. They provide a consistent interface for prompting and generating responses, making it easy to switch between different providers without changing the core logic of your application.

## Available Providers
You can use the following generation providers with Active Agent:
::: code-group

<<< @/../test/dummy/app/agents/open_ai_agent.rb#snippet{ruby:line-numbers} [OpenAI]

<<< @/../test/dummy/app/agents/anthropic_agent.rb {ruby} [Anthropic]

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

<<< @/../test/generation_provider_examples_test.rb#generation_response_usage{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/generation-provider-examples-test.rb-test-response-object-usage.md -->
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

## Configuration Precedence

ActiveAgent follows a clear hierarchy for configuration parameters, ensuring that you have fine-grained control over your AI generation settings. Parameters can be configured at multiple levels, with higher-priority settings overriding lower-priority ones.

### Precedence Order (Highest to Lowest)

1. **Runtime Options** - Parameters passed directly to the `prompt` method
2. **Agent Options** - Parameters defined in `generate_with` at the agent class level
3. **Global Configuration** - Parameters in `config/active_agent.yml`

This hierarchy allows you to:
- Set sensible defaults globally
- Override them for specific agents
- Make runtime adjustments for individual requests

### Example: Configuration Precedence in Action

<<< @/../test/agents/configuration_precedence_test.rb#test_configuration_precedence{ruby:line-numbers}

### Data Collection Precedence Example

The `data_collection` parameter for OpenRouter follows the same precedence rules:

<<< @/../test/agents/configuration_precedence_test.rb#test_data_collection_precedence{ruby:line-numbers}

### Key Principles

#### 1. Runtime Always Wins
Runtime options in the `prompt` method override all other configurations. See the test demonstrating this behavior:

<<< @/../test/agents/configuration_precedence_test.rb#runtime_options_override{ruby:line-numbers}

#### 2. Nil Values Don't Override  
Nil values passed at runtime don't override existing configurations:

<<< @/../test/agents/configuration_precedence_test.rb#nil_values_dont_override{ruby:line-numbers}

#### 3. Agent Configuration Overrides Global
Agent-level settings take precedence over global configuration files:

<<< @/../test/agents/configuration_precedence_test.rb#agent_overrides_config{ruby:line-numbers}

### Supported Runtime Options

The following options can be overridden at runtime:

- `:model` - The AI model to use
- `:temperature` - Creativity/randomness (0.0-1.0)
- `:max_tokens` - Maximum response length
- `:stream` - Enable streaming responses
- `:top_p` - Nucleus sampling parameter
- `:frequency_penalty` - Reduce repetition
- `:presence_penalty` - Encourage topic diversity
- `:response_format` - Structured output format
- `:seed` - For reproducible outputs
- `:stop` - Stop sequences
- `:tools_choice` - Tool selection strategy
- `:data_collection` - Privacy settings (OpenRouter)

### Best Practices

1. **Use Global Config for Defaults**: Set organization-wide defaults in `config/active_agent.yml`
2. **Agent-Level for Specific Needs**: Override in `generate_with` for agent-specific requirements  
3. **Runtime for Dynamic Adjustments**: Use runtime options for user preferences or conditional logic

For a complete example showing all three levels working together, see:

<<< @/../test/agents/configuration_precedence_test.rb#test_configuration_precedence{ruby:line-numbers}

## Provider-Specific Documentation

For detailed documentation on specific providers and their features:

- [OpenAI Provider](/docs/generation-providers/openai-provider) - GPT-4, GPT-3.5, function calling, vision, and Azure OpenAI support
- [Anthropic Provider](/docs/generation-providers/anthropic-provider) - Claude 3.5 and Claude 3 models with extended context windows
- [Ollama Provider](/docs/generation-providers/ollama-provider) - Local LLM inference for privacy-sensitive applications
- [OpenRouter Provider](/docs/generation-providers/open-router-provider) - Multi-model routing with fallbacks, PDF processing, and vision support

