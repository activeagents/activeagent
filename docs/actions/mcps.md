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
| **DeepSeek**   | ✅      | Client-side — see below; the API ignores `mcp_servers` |
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

## DeepSeek

DeepSeek has no server-side MCP. It **ignores `mcp_servers` rather than rejecting it**, so a request carrying one returns `200` and the model answers without the server's data — a failure that looks like a poor answer rather than a configuration error.

ActiveAgent therefore runs the servers itself. The declaration is unchanged:

```ruby
class ResearchAgent < ApplicationAgent
  generate_with :deepseek, model: "deepseek-flash"

  def research(topic)
    prompt(
      "Find and summarize recent news about #{topic}.",
      mcps: [ { name: "firecrawl", url: "https://mcp.firecrawl.dev/YOUR_KEY/v2/mcp" } ]
    )
  end
end
```

What happens behind that:

1. Each declared server is connected to, and the tools it offers are listed.
2. Those tools are merged with any the agent declares, and sent to DeepSeek as ordinary tools.
3. When the model calls one, the call is routed to the server that owns it and the result is returned as a tool result.

The provider's tool loop is untouched — it is handed tools it can call and receives results, which is all it ever needed. `allowed_tools:` on a declaration restricts which of a server's tools are exposed.

::: warning Requires the `mcp` gem
Add `gem "mcp"` to your Gemfile. It is loaded only when a client-side bridge is built, so it stays optional for applications that do not use `mcps:` against a client-side provider. Without it, the error names the gem to add.
:::

::: tip
Two tools sharing a name are **refused** rather than resolved by guessing, since the model has no way to say which it meant. Rename one, or restrict a server with `allowed_tools:`.
:::

Because discovering tools means connecting to the servers, `preview` does not resolve `mcps:` — a preview must not perform I/O. It shows the agent's declared tools only.

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
