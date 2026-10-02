---
title: Model Context Protocols (MCP)
description: Connect agents to external services and APIs using the Model Context Protocol. Universal integration for tools and data sources.
---
# {{ $frontmatter.title }}

Connect agents to external services via [Model Context Protocol](https://modelcontextprotocol.io/) servers. MCP servers expose tools and data sources that agents can use automatically.

## Quick Start

<<< @/../test/docs/actions/mcps_examples_test.rb#quick_start_weather_agent {ruby:line-numbers}

## Provider Support

All providers accept `mcps:`. 🟩 means the provider runs a remote `url:` server; 🟦 means ActiveAgent runs it and exposes its tools as functions. A local `command:` server is always 🟦. Mock accepts declarations but does not call tools.

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

## MCP Format

A server uses either an HTTP `url:` or a local stdio `command:`.

```ruby
# Remote server, over HTTP
{
  name: "server_name",        # Optional: server identifier, defaults to the host
  url: "https://server.url",  # Required: MCP endpoint
  authorization: "token"      # Optional: auth token
}

# Local server, over stdio
{
  name: "server_name",             # Optional: server identifier, defaults to the command
  command: "mcp-server-files",     # Required: executable to run
  args: [ "--root", "/tmp" ],      # Optional: arguments
  env: { "TOKEN" => "secret" },    # Optional: environment
  read_timeout: 10                 # Optional: seconds to wait for an answer
}
```

`name:` defaults to the URL host or command executable. Set it explicitly when multiple servers share a host.

For `command:` servers, `read_timeout:` sets the response deadline in seconds (30 by default). For HTTP servers, `max_reconnection_wait:` configures the transport's reconnection limit.

On a cache miss, ActiveAgent connects during prompt setup to list tools. On a cache hit, it connects only if the model calls a tool. Connections close when the generation ends, including on error.

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

With `mcp_strategy: :auto`, ActiveAgent connects to each declared server, lists the tools it offers, and routes calls back to the appropriate server, avoiding silent failures from providers like DeepSeek that ignore `mcp_servers`.

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

Use `allowed_tools:` to expose only the tools the agent needs; every exposed schema is sent with each model request.

### Choosing the strategy

Use `mcp_strategy:` to choose where servers run:

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

## What it costs

Two different costs, and only one of them can be cached.

Fetching a server's tool list takes a handshake and a `tools/list` round trip — about 1.1s in a hosted-server measurement. ActiveAgent caches schemas in process memory for five minutes by default:

```ruby
ActiveAgent::Providers::MCPToolCache.configure(ttl: 300, max_entries: 100)
```

Override the process-level cache setting for one generation with `mcp_cache: false`:

```ruby
prompt(
  "Inspect this site",
  mcp_cache: false,
  mcps: [ { name: "firecrawl", url: ENV.fetch("FIRECRAWL_MCP_URL") } ]
)
```

Entries are isolated by endpoint, bearer credential, command/arguments/environment, and `allowed_tools:`. Only server tool schemas are cached — never prompts, results, or agent-declared tools. Credentials are hashed, not stored as cache keys.

A cache miss connects once to list tools. A cache hit avoids connecting unless the model calls a tool; `command:` servers start on first use in that generation.

The process-local cache holds no sockets or child processes. Clear it after a server update with `MCPToolCache.clear!`.

::: warning Replaying MCP traffic in tests
The cache changes request counts. Since MCP calls POST to one URL, URI-matched cassettes replay in order and become misaligned when a cached `tools/list` is skipped. Disable caching in cassette-backed tests and reset it between examples:

```ruby
ActiveAgent::Providers::MCPToolCache.configure(enabled: false) # cassette-backed suites
ActiveAgent::Providers::MCPToolCache.reset!                    # or reset between examples
```
:::

**Sending the tool list with each request** cannot be cached away. Every API call is stateless and a model can only call a tool it was just told about, so the schemas go out on every turn of the tool loop and sit in the model's context. What you control is how much there is: a server offering 27 tools measured 14,659 input tokens per completion against 2,007 for one tool, and a tool loop pays that on each turn. `allowed_tools:` is the lever — restrict a server to what the agent actually calls.

Providers cache the repeated prefix on their side to soften this, but ActiveAgent does not currently mark Anthropic's cache breakpoint, so Anthropic bills the full list each turn. OpenAI and DeepSeek apply prefix caching automatically.

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
