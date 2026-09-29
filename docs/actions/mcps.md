---
title: Model Context Protocols (MCP)
description: Connect agents to external services and APIs using the Model Context Protocol. Universal integration for tools and data sources.
---
# {{ $frontmatter.title }}

Connect agents to external services via [Model Context Protocol](https://modelcontextprotocol.io/) servers. MCP servers expose tools and data sources that agents can use automatically.

## Quick Start

<<< @/../test/docs/actions/mcps_examples_test.rb#quick_start_weather_agent {ruby:line-numbers}

## Provider Support

Every provider can use MCP servers. Where a provider's own API speaks MCP it runs the server itself, and the tool schemas never enter the prompt; everywhere else ActiveAgent runs the server and hands the model the tools it offers. See [Who runs the server](#who-runs-the-server).

| Provider                      | `url:` servers | `command:` servers | Notes |
|:------------------------------|:--------------:|:------------------:|:------|
| **Anthropic**                 | 🟩             | 🟦                 | Provider support is beta |
| **Azure**                     | 🟦             | 🟦                 | |
| **DeepSeek**                  | 🟦             | 🟦                 | Ignores `mcp_servers` rather than rejecting it |
| **Gemini**                    | 🟦             | 🟦                 | |
| **Mock**                      | 🟦             | 🟦                 | Accepted, but Mock never emits tool calls |
| **Ollama**                    | 🟦             | 🟦                 | |
| **OpenAI** (Chat Completions) | 🟦             | 🟦                 | |
| **OpenAI** (Responses API)    | 🟩             | 🟦                 | |
| **OpenRouter**                | 🟦             | 🟦                 | |
| **Requesty**                  | 🟦             | 🟦                 | |
| **RubyLLM**                   | 🟦             | 🟦                 | |

🟩 the provider runs the server · 🟦 ActiveAgent runs the server

A `command:` server is always run by ActiveAgent, even on a provider that accepts an MCP URL: a provider can be handed a URL, but not a process on your machine to spawn and talk to.

## MCP Format

A server is reached either over HTTP (`url:`) or by running a local process that speaks MCP over stdio (`command:`). Declare one or the other.

```ruby
# Remote server, over HTTP
{
  name: "server_name",        # Required: server identifier
  url: "https://server.url",  # Required: MCP endpoint
  authorization: "token"      # Optional: auth token
}

# Local server, over stdio
{
  name: "server_name",             # Required: server identifier
  command: "mcp-server-files",     # Required: executable to run
  args: [ "--root", "/tmp" ],      # Optional: arguments
  env: { "TOKEN" => "secret" }     # Optional: environment
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

## Who runs the server

Declaring `mcps:` is by default a passthrough: the declaration becomes the provider's own `mcp_servers` parameter and the provider connects, lists the tools, and calls them. That works only where the provider implements MCP.

Where it does not, the failure is quiet. DeepSeek, for example, **ignores `mcp_servers` rather than rejecting it**, so a request carrying one returns `200` and the model answers without the server's data — a failure that looks like a poor answer rather than a configuration error.

ActiveAgent closes that gap without the provider's help. It connects to each declared server itself, lists the tools it offers, merges them with any you declared, and answers tool calls on the server that owns them. The provider's tool loop is untouched: it is handed tools it can call and receives results, which is all it ever needed. The declaration is unchanged either way:

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
2. Those tools are merged with any the agent declares, and sent to the provider as ordinary tools.
3. When the model calls one, the call is routed to the server that owns it and the result is returned as a tool result.

`allowed_tools:` on a declaration restricts which of a server's tools are exposed, which is worth doing on a server that offers many — every tool it lists costs tokens on every request, whether or not the model calls it.

### Choosing the strategy

The default, `mcp_strategy: :auto`, hands each server to the provider if the provider can serve it and runs it client-side otherwise. Set it explicitly when you want to be sure:

| Strategy        | Behavior |
|:----------------|:---------|
| `:auto` (default) | The provider serves what it can; ActiveAgent runs the rest. |
| `:client`       | ActiveAgent runs every declared server, including ones the provider could serve. |
| `:server`       | Every declared server must be served by the provider. Raises `ArgumentError` naming what the provider can serve if it cannot. |

```ruby
class ResearchAgent < ApplicationAgent
  generate_with :anthropic, model: "claude-haiku-4-5"

  def research(topic)
    prompt(
      "Find and summarize recent news about #{topic}.",
      # Run this one ourselves rather than handing it to Anthropic.
      mcp_strategy: :client,
      mcps: [ { name: "firecrawl", url: "https://mcp.firecrawl.dev/YOUR_KEY/v2/mcp" } ]
    )
  end
end
```

A local (`command:`) server always runs client-side, so `mcp_strategy: :server` with one raises even on Anthropic or OpenAI Responses.

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
