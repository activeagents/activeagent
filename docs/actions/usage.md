---
title: Usage Statistics
description: Track token usage and performance metrics across all AI providers with normalized usage objects.
---
# {{ $frontmatter.title }}

Track token consumption and performance metrics from AI provider responses. All providers return normalized usage statistics for consistent cost tracking and monitoring.

::: tip Monitor Usage in Production
See [Instrumentation](/framework/instrumentation) to monitor usage statistics in real-time using ActiveSupport::Notifications.
:::

## Accessing Usage

Get usage statistics from any response:

<<< @/../test/docs/actions/usage_examples_test.rb#accessing_usage{ruby:line-numbers}

## Common Fields

These fields work across all providers:

<<< @/../test/docs/actions/usage_examples_test.rb#common_fields{ruby:line-numbers}

## Provider-Specific Fields

Access advanced metrics when available:

::: code-group
<<< @/../test/docs/actions/usage_examples_test.rb#provider_specific_openai{ruby:line-numbers} [OpenAI]
<<< @/../test/docs/actions/usage_examples_test.rb#provider_specific_anthropic{ruby:line-numbers} [Anthropic]
<<< @/../test/docs/actions/usage_examples_test.rb#provider_specific_ollama{ruby:line-numbers} [Ollama]
:::

## Provider Details

Raw provider data preserved in `provider_details`:

::: code-group
<<< @/../test/docs/actions/usage_examples_test.rb#provider_details_openai{ruby:line-numbers} [OpenAI]
<<< @/../test/docs/actions/usage_examples_test.rb#provider_details_ollama{ruby:line-numbers} [Ollama]
:::

## Cost Tracking

Calculate costs using token counts:

<<< @/../test/docs/actions/usage_examples_test.rb#cost_tracking{ruby:line-numbers}

**Monitor costs in production:** Use [Instrumentation](/framework/instrumentation#cost-tracking) to automatically track costs across all requests.

## Embeddings Usage

Embedding responses have zero output tokens:

<<< @/../test/docs/actions/usage_examples_test.rb#embeddings_usage{ruby:line-numbers}

## Field Mapping

How provider fields map to normalized names:

| Provider | input_tokens | output_tokens | total_tokens |
|----------|--------------|---------------|--------------|
| OpenAI Chat | prompt_tokens | completion_tokens | total_tokens |
| OpenAI Embed | prompt_tokens | 0 | total_tokens |
| OpenAI Responses | input_tokens | output_tokens | total_tokens |
| Anthropic | input_tokens | output_tokens | calculated |
| Ollama | prompt_eval_count | eval_count | calculated |
| OpenRouter | prompt_tokens | completion_tokens | total_tokens |

**Note:** `total_tokens` is automatically calculated as `input_tokens + output_tokens` when not provided by the provider.
