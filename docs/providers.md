---
title: Providers
description: Connect your agents to AI services through a unified interface. Switch between OpenAI, Anthropic, local models, or testing mocks without changing agent code.
---
# {{ $frontmatter.title }}

Providers connect your agents to AI services through a unified interface. Switch between OpenAI, Anthropic, local models, or testing mocks without changing agent code.

## Available Providers

::: code-group

<<< @/../test/dummy/app/agents/providers/anthropic_agent.rb#agent{ruby} [Anthropic]

<<< @/../test/dummy/app/agents/providers/ollama_agent.rb#agent{ruby} [Ollama]

<<< @/../test/dummy/app/agents/providers/open_ai_agent.rb#agent{ruby} [OpenAI]

<<< @/../test/dummy/app/agents/providers/open_router_agent.rb#agent{ruby} [OpenRouter]

<<< @/../test/dummy/app/agents/providers/mock_agent.rb#agent{ruby} [Mock]

:::

## Choosing a Provider

### [Anthropic](/providers/anthropic)
**Best for:** Complex reasoning, coding tasks, long context

Claude Sonnet 4.5, Haiku 4.5, and Opus 4.1 models. Extended thinking mode for deep analysis. 200K-1M context windows with up to 64K token outputs.

**Choose when:** You need exceptional reasoning, prefer Claude's outputs, or require very long context windows. Strong at coding and analysis.

### [Ollama](/providers/ollama)
**Best for:** Local inference, privacy-sensitive data, development without API costs

Run Llama 3, Mistral, Gemma, CodeLlama, and other open models locally. No API keys required. Full control over data.

**Choose when:** Data cannot leave your infrastructure, you're developing offline, or you want to avoid API costs. Requires local setup.

### [Azure OpenAI](/providers/azure)
**Best for:** Enterprise deployments, data residency requirements, existing Azure infrastructure

Azure-hosted OpenAI models with dedicated endpoints, Azure-specific authentication (api-key header), and deployment-based model selection. Uses Chat Completions API.

**Choose when:** Your organization requires Azure compliance, data residency, or you already use Azure infrastructure. Same models as OpenAI but hosted on Azure.

### [OpenAI](/providers/open_ai)
**Best for:** Production applications, advanced reasoning, vision tasks

GPT-4o, GPT-4.1, GPT-5, and o3 models. Two APIs available: Responses API (default) with built-in web search, image generation, and MCP integration, or Chat Completions API for standard interactions. 128K-200K context windows.

**Choose when:** You need reliable, high-quality responses with strong reasoning. Vision support and structured output work well.

### [OpenRouter](/providers/open_router)
**Best for:** Multi-model flexibility, cost optimization, experimentation

Access 200+ models from OpenAI, Anthropic, Google, Meta, and more through one API. Intelligent routing, automatic fallbacks, multimodal support, PDF processing.

**Choose when:** You want to compare models, need fallback options, or want flexible provider switching. Good for reducing vendor lock-in.

### [Mock](/providers/mock)
**Best for:** Testing, development, offline work

Predictable responses (pig latin conversion) with no API calls. Simulates real provider behavior for testing agent logic.

**Choose when:** Writing tests, developing without network access, or avoiding API costs during development.

## Configuration

Configuration applies in order of precedence:

```ruby
# 1. Global config (config/active_agent.yml)
# temperature: 0.7

class MyAgent < ApplicationAgent
  # 2. Agent-level config
  generate_with :openai, temperature: 0.5

  def analyze
    # 3. Runtime config (highest precedence)
    prompt(temperature: 0.9)
  end
end
```

For environment-specific settings and advanced configuration, see **[Configuration](/framework/configuration)**.

## Response Objects

All providers return standardized response objects:

<<< @/../test/docs/framework/providers_examples_test.rb#generation_response_usage{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/providers-examples-test.rb-test-response-object-usage.md -->
:::

**Common attributes:**
- `message` / `messages` - Response content and conversation history
- `usage` - Normalized token usage statistics (see **[Usage Statistics](/actions/usage)**)
- `raw_request` / `raw_response` - Provider-specific data for debugging
- `context` - Original request sent to provider

Embedding responses use `data` instead of `message`:

```ruby
response = generation.embed_now
vector = response.data.first[:embedding]  # Array of floats
```

For embedding documentation including similarity search and batch processing, see **[Embeddings](/actions/embeddings)**.
