---
title: Tools
description: Extend agents with callable functions that LLMs can trigger during generation. Unified interface across providers for function calling.
---
# {{ $frontmatter.title }}

Tools extend agents with callable functions that LLMs can trigger during generation. ActiveAgent provides a unified interface across providers while highlighting provider-specific capabilities.

## Quick Start

Define a method in your agent and register it as a tool:

<<< @/../test/docs/actions/tools_examples_test.rb#quick_start_weather_agent {ruby:line-numbers}
<<< @/../test/docs/actions/tools_examples_test.rb#quick_start_weather_usage {ruby:line-numbers}

The LLM calls `get_weather` automatically when it needs weather data, and uses the result to generate its response.

## Provider Support Matrix

| Provider       | Functions | Server-side Tools | Notes |
|:---------------|:---------:|:-----------------:|:------|
| **OpenAI**     | 🟩        | 🟩                | Server-side tools require Responses API |
| **Anthropic**  | 🟩        | 🟩                | Full support for built-in tools |
| **OpenRouter** | 🟩        | ❌                | Model-dependent capabilities |
| **Ollama**     | 🟩        | ❌                | Model-dependent capabilities |
| **RubyLLM**    | 🟩        | ❌                | Depends on underlying provider/model |
| **Mock**       | 🟦        | ❌                | Accepted but not enforced |

For **MCP (Model Context Protocol)** support, see the [MCP documentation](/actions/mcps).

## Functions

Functions are callable methods in your agent that LLMs can trigger with appropriate parameters. All providers support the **common format** described above.

### Basic Function Registration

Using the common format, register functions by passing tool definitions to the `tools` parameter:

::: code-group
<<< @/../test/docs/actions/tools_examples_test.rb#anthropic_basic_function {ruby:line-numbers} [Anthropic]
<<< @/../test/docs/actions/tools_examples_test.rb#ollama_basic_function {ruby:line-numbers} [Ollama]
<<< @/../test/docs/actions/tools_examples_test.rb#openai_basic_function {ruby:line-numbers} [OpenAI]
<<< @/../test/docs/actions/tools_examples_test.rb#openrouter_basic_function {ruby:line-numbers} [OpenRouter]
:::

When the LLM decides to call a tool, ActiveAgent routes the call to your agent method and returns the result automatically.

## Common Tools Format (Recommended)

ActiveAgent supports a **universal common format** for tool definitions that works seamlessly across all providers. This format eliminates the need to learn provider-specific syntax and makes your code portable.

### Format Specification

```ruby
{
  name: "function_name",              # Required: function name to call
  description: "What it does",        # Required: clear description for LLM
  parameters: {                       # Required: JSON Schema for parameters
    type: "object",
    properties: {
      param_name: {
        type: "string",
        description: "Parameter description"
      }
    },
    required: ["param_name"]
  }
}
```

### Cross-Provider Example

The same tool definition works everywhere:

<<< @/../test/docs/actions/tools_examples_test.rb#cross_provider_module {ruby:line-numbers}

::: code-group
<<< @/../test/docs/actions/tools_examples_test.rb#cross_provider_anthropic {ruby:line-numbers} [Anthropic]
<<< @/../test/docs/actions/tools_examples_test.rb#cross_provider_ollama{ruby:line-numbers} [Ollama]
<<< @/../test/docs/actions/tools_examples_test.rb#cross_provider_openai{ruby:line-numbers} [OpenAI]
<<< @/../test/docs/actions/tools_examples_test.rb#cross_provider_openrouter {ruby:line-numbers} [OpenRouter]
:::

### Alternative: `input_schema` Key

You can also use `input_schema` instead of `parameters` - both work identically:

```ruby
{
  name: "get_weather",
  description: "Get current weather",
  input_schema: {  # Alternative to 'parameters'
    type: "object",
    properties: { ... }
  }
}
```

ActiveAgent automatically converts between common format and each provider's native format behind the scenes.

### Tool Choice Control

Control when and which tools the LLM uses with the `tool_choice` parameter:

```ruby
# Auto (default) - Let the model decide whether to use tools
prompt(message: "...", tools: tools, tool_choice: "auto")

# Required - Force the model to use at least one tool
prompt(message: "...", tools: tools, tool_choice: "required")

# None - Prevent tool usage entirely
prompt(message: "...", tools: tools, tool_choice: "none")

# Specific tool - Force a particular tool (common format)
prompt(message: "...", tools: tools, tool_choice: { name: "get_weather" })
```

ActiveAgent automatically maps these common values to provider-specific formats:
- **OpenAI**: `"auto"`, `"required"`, `"none"`, or `{type: "function", function: {name: "..."}}`
- **Anthropic**: `{type: :auto}`, `{type: :any}`, `{type: :tool, name: "..."}`
- **OpenRouter**: `"auto"`, `"any"` (equivalent to "required")
- **Ollama**: Model-dependent tool choice support

## Server-Side Tools (Provider-Specific)

Some providers offer built-in tools that run on their servers, providing capabilities like web search and code execution without custom implementation.

### OpenAI Built-in Tools

OpenAI's **Responses API** provides several built-in tools (requires GPT-5, GPT-4.1, o3, etc.) including Web Search for current information, File Search for querying vector stores, and other tools like image generation, code interpreter, and computer use. For complete details and examples, see [OpenAI's tools documentation](https://platform.openai.com/docs/guides/tools) and the [OpenAI Provider documentation](/providers/open_ai#built-in-tools).

### Anthropic Built-in Tools

Anthropic provides web access and specialized capabilities including Web Search for real-time information, Web Fetch (Beta) for specific URLs, Extended Thinking to show reasoning processes, and Computer Use (Beta) for interface interaction. For complete details and examples, see [Anthropic's tool use documentation](https://docs.claude.com/en/docs/agents-and-tools/tool-use/overview).

## Troubleshooting

### Tool Not Being Called

If the LLM doesn't call your function when expected, improve the tool description or use `tool_choice: "required"` to force tool usage.

### Invalid Parameters

If the LLM passes unexpected parameters, add detailed parameter descriptions with `enum` for restricted choices and mark required parameters explicitly.

## Related Documentation

- [MCP (Model Context Protocol)](/actions/mcps) - Connect to external services via MCP
- [Agents](/agents) - Understand the agent lifecycle and callbacks
- [Generation](/agents/generation) - Execute tool-enabled generations
- [Messages](/actions/messages) - Learn about conversation structure
- [Streaming](/agents/streaming) - Use tools with streaming responses
- [Configuration](/framework/configuration) - Configure tool behavior across environments
- [OpenAI Provider](/providers/open_ai) - OpenAI-specific tool features
- [Anthropic Provider](/providers/anthropic) - Anthropic-specific capabilities
