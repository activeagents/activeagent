---
title: Model Context Protocols (MCP)
description: Connect agents to external services and APIs using the Model Context Protocol. Universal integration for tools and data sources.
---
# {{ $frontmatter.title }}

Connect agents to external services via [Model Context Protocol](https://modelcontextprotocol.io/) servers. MCP servers expose tools and data sources that agents can use automatically.

## Quick Start

<<< @/../test/docs/actions/mcps_examples_test.rb#quick_start_weather_agent {ruby:line-numbers}

## Provider Support

| Provider       | Support | Notes |
|:---------------|:-------:|:------|
| **OpenAI**     | ✅      | Via Responses API |
| **Anthropic**  | ⚠️      | Beta |
| **OpenRouter** | 🚧      | In development |
| **Ollama**     | ❌      | Not supported |
| **RubyLLM**    | ❌      | Not supported (use provider-specific integration) |
| **Mock**       | ❌      | Not supported |

## MCP Format

```ruby
{
  name: "server_name",        # Required: server identifier
  url: "https://server.url",  # Required: MCP endpoint
  authorization: "token"      # Optional: auth token
}
```

### Single Server

<<< @/../test/docs/actions/mcps_examples_test.rb#single_server_data_agent {ruby:line-numbers}

### Multiple Servers

<<< @/../test/docs/actions/mcps_examples_test.rb#multiple_servers_integrated_agent {ruby:line-numbers}

### With Function Tools

<<< @/../test/docs/actions/mcps_examples_test.rb#hybrid_agent_with_tools {ruby:line-numbers}

## OpenAI

OpenAI supports MCP via the Responses API with pre-built connectors and custom servers.

### Pre-built Connectors

<<< @/../test/docs/actions/mcps_examples_test.rb#openai_prebuilt_connectors {ruby:line-numbers}

Available: Dropbox, Google Drive, GitHub, Slack, and more. See [OpenAI's MCP docs](https://platform.openai.com/docs/guides/mcp) for the full list.

### Custom Servers

<<< @/../test/docs/actions/mcps_examples_test.rb#openai_custom_servers {ruby:line-numbers}

## Anthropic

Anthropic supports MCP servers via the `mcp_servers` parameter (beta). Up to 20 servers per request.

<<< @/../test/docs/actions/mcps_examples_test.rb#anthropic_basic_mcp {ruby:line-numbers}

See [Anthropic's MCP docs](https://docs.anthropic.com/en/docs/build-with-claude/mcp) for details.

## Native Formats

ActiveAgent converts the common format to provider-specific formats automatically. Use native formats only if needed for provider-specific features.

::: code-group
<<< @/../test/docs/actions/mcps_examples_test.rb#native_formats_openai {ruby:line-numbers} [OpenAI]
<<< @/../test/docs/actions/mcps_examples_test.rb#native_formats_anthropic {ruby:line-numbers} [Anthropic]
:::

## Troubleshooting

**Server not responding:** Verify the URL is correct and accessible from your environment.

**Authorization failures:** Check token validity, permissions, and expiration.

**Tools not available:** Ensure the server implements MCP correctly and returns valid tool definitions.

## Related

- [Tools](/actions/tools) - Function tools and tool choice
- [OpenAI Provider](/providers/open_ai) - OpenAI-specific features
- [Anthropic Provider](/providers/anthropic) - Anthropic-specific features
