---
title: DeepSeek Provider
description: Use DeepSeek models through their OpenAI-compatible API, with native JSON output, tool calling, and thinking mode.
---
# {{ $frontmatter.title }}

The DeepSeek provider talks to DeepSeek's OpenAI-compatible API. Because the API follows OpenAI's shape, this provider extends the OpenAI Chat provider and inherits its request and response handling — but JSON output and tool calling are served natively by DeepSeek rather than emulated, and the request is adapted where DeepSeek diverges (see [Differences from the OpenAI Provider](#differences-from-the-openai-provider)).

## Configuration

### Basic Setup

```ruby
class AnalysisAgent < ApplicationAgent
  generate_with :deepseek, model: "deepseek-flash"

  def summarize
    prompt("Summarize this in one sentence: …")
  end
end
```

### Configuration File

```yaml
# config/active_agent.yml
deepseek:
  service: "DeepSeek"
  api_key: <%= Rails.application.credentials.dig(:deepseek, :api_key) %>
  model: "deepseek-flash"
```

`service` selects the provider class, so it must be `"DeepSeek"` — the block name is free.

### Environment Variables

```bash
DEEPSEEK_API_KEY=sk-...
```

DeepSeek has no organization or project scoping, so `organization_id` and `project_id` are not read from `OPENAI_*` variables. Nothing foreign is attached to a request.

## Models

`deepseek-flash` is the default when a prompt does not name a model. DeepSeek's API requires a model and has no default of its own, so naming one in configuration is a convenience rather than an override.

For the current model list, context windows, and pricing, see [DeepSeek's documentation](https://api-docs.deepseek.com/quick_start/pricing).

DeepSeek's pricing is time-of-day dependent, and thinking mode is billed whether or not the answer needed it — see below before assuming a per-request cost.

## Thinking Mode

DeepSeek runs thinking unless told otherwise, and bills the reasoning whether or not the answer needed it. For extraction and classification work, that reasoning is often charged for and discarded: measured against `deepseek-flash`, a one-line JSON extraction cost **83 output tokens at DeepSeek's default against 7 with thinking disabled**.

The provider does not override this, so requests get whichever behaviour DeepSeek currently considers best. Opt out per prompt:

```ruby
class ColorsAgent < ApplicationAgent
  generate_with :deepseek, model: "deepseek-flash"

  def primary_colors
    prompt(
      "Return the three primary colors as JSON.",
      thinking: { type: "disabled" }
    )
  end
end
```

Thinking is also why sampling parameters can appear to do nothing. DeepSeek **ignores `temperature`, `presence_penalty`, and `frequency_penalty` while thinking is on**, so a prompt that needs those to bite has to disable thinking first.

::: tip
If you are tuning a prompt's sampling behaviour, disable thinking. Otherwise the parameters are accepted, ignored, and leave you tuning something that does not apply.
:::

## Structured Output

Both structured modes are native to DeepSeek — neither needs an assistant prefill, and the response parses the same way as any OpenAI-compatible provider:

```ruby
class ColorsAgent < ApplicationAgent
  generate_with :deepseek, model: "deepseek-flash"

  # A JSON object, with no schema constraint
  def as_object
    prompt("Return the three primary colors as JSON.", response_format: :json_object)
  end

  # Constrained to a schema
  def as_schema
    prompt("Return the three primary colors.", response_format: :json_schema)
  end
end
```

See **[Structured Output](/actions/structured_output)** for the common format, schema placement, and validation behaviour, which are shared across providers.

## Tool Calling

Tool definitions are passed through to DeepSeek, which returns real tool calls. Nothing about the common format changes:

```ruby
class WeatherAgent < ApplicationAgent
  generate_with :deepseek, model: "deepseek-flash"

  def forecast(city)
    prompt("What is the forecast for #{city}?", tools: [ WeatherTool ])
  end
end
```

## MCP Runs Client-Side

DeepSeek has no server-side MCP: it **ignores `mcp_servers` rather than rejecting it**, so a request carrying one returns `200` with no tool call and the model answers without the data the server would have supplied. There is no error to notice — the prompt simply lacks its content.

ActiveAgent works around this by running the servers itself, so `mcps:` behaves the same as it does elsewhere:

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

Add `gem "mcp"` to your Gemfile; it is loaded only when a bridge is needed. See **[MCP](/actions/mcps)** for the details, including how name collisions are handled.

If a server is only ever used to fetch a page, fetching it in Ruby and passing the content in is cheaper — one completion instead of two:

```ruby
def select_currency_code
  content = API::Firecrawl::Scrape.new.markdown(params[:url])

  prompt(
    "URL: `#{params[:url]}`\n\nContent:\n\n#{content}",
    response_format: :json_object
  )
end
```

## Differences from the OpenAI Provider

| | Behaviour |
|---|---|
| **Message roles** | DeepSeek accepts only `system`, `user`, `assistant`, `tool`, and `latest_reminder`. It **rejects the rest with a 422** rather than ignoring them. `instructions: true` is expressed by the OpenAI transforms as a `developer` message, and DeepSeek does not accept that role, so this provider folds instructions into `system` messages first. |
| **Organization / project** | Not sent; DeepSeek has no such scoping. |
| **`temperature` and friends** | Accepted, but ignored while thinking is on. |
| **MCP** | Runs client-side. See [above](#mcp-runs-client-side). |

## See Also

- **[Structured Output](/actions/structured_output)** - JSON response formatting across providers
- **[Tools](/actions/tools)** - Defining and calling tools
- **[Usage Statistics](/actions/usage)** - Tracking tokens, including reasoning tokens
- **[DeepSeek API Documentation](https://api-docs.deepseek.com)**
