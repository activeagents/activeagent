---
title: Atlas Cloud Provider
description: Use Atlas Cloud text models through its OpenAI-compatible Chat Completions API.
---
# {{ $frontmatter.title }}

The Atlas Cloud provider connects Active Agent to Atlas Cloud's OpenAI-compatible Chat Completions API. It supports the standard Active Agent chat features, including streaming, structured output, and tool calling when the selected model supports them.

## Installation

Atlas Cloud uses the `openai` gem:

```bash
bundle add openai
```

## Configuration

Set the API key in your environment:

```bash
ATLASCLOUD_API_KEY=your-api-key
```

Configure the provider in `config/active_agent.yml`:

```yaml
development:
  atlas_cloud:
    service: "AtlasCloud"
    api_key: <%= ENV["ATLASCLOUD_API_KEY"] %>
    model: "qwen/qwen3.8-max"
```

Then select it from an agent:

<<< @/../test/dummy/app/agents/providers/atlas_cloud_agent.rb#agent{ruby}

The provider defaults to `https://api.atlascloud.ai/v1`. You can override `base_url` in the provider configuration when routing through a compatible proxy.

## Model Selection

Atlas Cloud model identifiers use a `provider/model` format. Query the current catalog before selecting a model:

```bash
curl https://api.atlascloud.ai/v1/models \
  -H "Authorization: Bearer $ATLASCLOUD_API_KEY"
```

Use the returned model ID as the `model` value. Model capabilities vary, so verify streaming, structured output, or tool support for the chosen model.
