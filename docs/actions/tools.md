# Tools

Tools extend agents with callable functions that LLMs can trigger during generation. ActiveAgent provides a unified interface across providers while highlighting provider-specific capabilities.

## Quick Start

Define a method in your agent and register it as a tool:

<<< @/../test/docs/actions/tools_examples_test.rb#quick_start_weather_agent {ruby:line-numbers}
<<< @/../test/docs/actions/tools_examples_test.rb#quick_start_weather_usage {ruby:line-numbers}

The LLM calls `get_weather` automatically when it needs weather data, and uses the result to generate its response.

## Provider Support Matrix

| Provider       | Functions | Server-side Tools | MCP Support | Notes |
|:---------------|:---------:|:-----------------:|:-----------:|:------|
| **OpenAI**     | 🟩        | 🟩                | 🟩          | Server-side tools and MCP require Responses API |
| **Anthropic**  | 🟩        | 🟩                | 🟨          | MCP in beta |
| **OpenRouter** | 🟩        | ❌                | 🟦          | MCP via converted tool definitions; model-dependent capabilities |
| **Ollama**     | 🟩        | ❌                | ❌          | Model-dependent capabilities |
| **Mock**       | 🟦        | ❌                | ❌          | Accepted but not enforced |

## Functions (Universal Support)

Functions are the core tool capability supported by all providers. Define methods in your agent that the LLM can call with appropriate parameters.

### Basic Function Registration

Register functions by passing tool definitions to the `tools` parameter:

::: code-group
<<< @/../test/docs/actions/tools_examples_test.rb#anthropic_basic_function {ruby:line-numbers} [Anthropic]
<<< @/../test/docs/actions/tools_examples_test.rb#ollama_basic_function {ruby:line-numbers} [Ollama]
<<< @/../test/docs/actions/tools_examples_test.rb#openai_basic_function {ruby:line-numbers} [OpenAI]
<<< @/../test/docs/actions/tools_examples_test.rb#openrouter_basic_function {ruby:line-numbers} [OpenRouter]
:::

When the LLM decides to call a tool, ActiveAgent routes the call to your agent method and returns the result automatically.

### Tool Choice Control

Control which tools the LLM can use:

```ruby
# Let the model decide (default)
prompt(message: "...", tools: tools, tool_choice: "auto")

# Force the model to use a tool
prompt(message: "...", tools: tools, tool_choice: "required")

# Prevent tool usage
prompt(message: "...", tools: tools, tool_choice: "none")

# Force a specific tool (provider-dependent)
prompt(message: "...", tools: tools, tool_choice: { type: "function", name: "get_weather" })
```

## Server-Side Tools (Provider-Specific)

Some providers offer built-in tools that run on their servers, providing capabilities like web search and code execution without custom implementation.

### OpenAI Built-in Tools

OpenAI's **Responses API** provides several built-in tools (requires GPT-5, GPT-4.1, o3, etc.) including Web Search for current information, File Search for querying vector stores, and other tools like image generation, code interpreter, and computer use. For complete details and examples, see [OpenAI's tools documentation](https://platform.openai.com/docs/guides/tools) and the [OpenAI Provider documentation](/providers/open_ai#built-in-tools).

### Anthropic Built-in Tools

Anthropic provides web access and specialized capabilities including Web Search for real-time information, Web Fetch (Beta) for specific URLs, Extended Thinking to show reasoning processes, and Computer Use (Beta) for interface interaction. For complete details and examples, see [Anthropic's tool use documentation](https://docs.claude.com/en/docs/agents-and-tools/tool-use/overview).

## Model Context Protocol (MCP)

MCP (Model Context Protocol) enables agents to connect to external services and APIs. Think of it as a universal adapter for integrating tools and data sources.

### OpenAI MCP Integration

OpenAI supports MCP through their Responses API in two ways: pre-built connectors for popular services (Dropbox, Google Drive, GitHub, Slack, and more) and custom MCP servers. For complete details on OpenAI's MCP support, connector IDs, and configuration options, see [OpenAI's MCP documentation](https://platform.openai.com/docs/guides/mcp).

### Anthropic MCP Integration

Anthropic supports MCP servers via the `mcp_servers` parameter (beta feature). You can connect up to 20 MCP servers per request. For the latest on Anthropic's MCP implementation and configuration, see [Anthropic's MCP documentation](https://docs.anthropic.com/en/docs/build-with-claude/mcp).

### OpenRouter MCP Integration

::: info Coming Soon
MCP support for OpenRouter is currently under development and will be available in a future release.
:::

## Troubleshooting

### Tool Not Being Called

If the LLM doesn't call your function when expected, improve the tool description or use `tool_choice: "required"` to force tool usage.

### Invalid Parameters

If the LLM passes unexpected parameters, add detailed parameter descriptions with `enum` for restricted choices and mark required parameters explicitly.

## Related Documentation

- [Messages](/actions/messages) - Learn about conversation structure
- [Streaming](/agents/streaming) - Use tools with streaming responses
- [OpenAI Provider](/providers/open_ai) - OpenAI-specific tool features
- [Anthropic Provider](/providers/anthropic) - Anthropic-specific capabilities
