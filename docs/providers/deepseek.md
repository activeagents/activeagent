---
title: DeepSeek Provider
description: Use DeepSeek models through their OpenAI-compatible API, with native JSON output, tool calling, and thinking mode.
---
# {{ $frontmatter.title }}

Use DeepSeek through its OpenAI-compatible API. JSON output and tool calling are native; ActiveAgent adapts message roles and other differences from OpenAI's API.

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

The `service` value must be `"DeepSeek"`; the configuration key can be named differently.

### Environment Variables

```bash
DEEPSEEK_API_KEY=sk-...
```

DeepSeek has no organization or project scoping; `OPENAI_*` organization and project variables are ignored.

## Models

The model defaults to `deepseek-flash`; DeepSeek's API requires a model.

For the current model list, context windows, and pricing, see [DeepSeek's documentation](https://api-docs.deepseek.com/quick_start/pricing).

DeepSeek's pricing varies by time of day. Thinking tokens are billed even when the answer does not use them.

## Thinking Mode

DeepSeek enables thinking by default. In one `deepseek-flash` JSON extraction, the default used **83 output tokens**, compared with **7** when thinking was disabled.

ActiveAgent leaves this default unchanged. Opt out per prompt:

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

DeepSeek ignores `temperature`, `presence_penalty`, and `frequency_penalty` while thinking is enabled. Disable thinking when you need those parameters to apply.

## Structured Output

DeepSeek supports `json_object` and `json_schema` natively:

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

Tool calling uses the common `tools:` format:

```ruby
class WeatherAgent < ApplicationAgent
  generate_with :deepseek, model: "deepseek-flash"

  def forecast(city)
    prompt("What is the forecast for #{city}?", tools: [ WeatherTool ])
  end
end
```

## MCP

DeepSeek silently ignores `mcp_servers`; ActiveAgent bridges `mcps:` as function tools. Add `gem "mcp"` to use the bridge. See [MCP support](/actions/mcps) for configuration and filtering.

## Differences from the OpenAI Provider

| | Behaviour |
|---|---|
| **Message roles** | DeepSeek accepts `system`, `user`, `assistant`, `tool`, and `latest_reminder`. ActiveAgent maps instructions to `system` because DeepSeek rejects `developer` with a 422. |
| **`temperature` and friends** | Accepted, but ignored while thinking is on. |

## See Also

- **[Structured Output](/actions/structured_output)** - JSON response formatting across providers
- **[Tools](/actions/tools)** - Defining and calling tools
- **[Usage Statistics](/actions/usage)** - Tracking tokens, including reasoning tokens
- **[DeepSeek API Documentation](https://api-docs.deepseek.com)**
