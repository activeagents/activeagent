---
title: Mock Provider
description: Testing provider for developing and testing agents without API calls or costs. Returns predictable pig latin responses and generates random embeddings.
---
# {{ $frontmatter.title }}

The Mock provider is designed for testing purposes, allowing you to develop and test agents without making actual API calls or incurring costs. It returns predictable responses by converting input text to pig latin and generates random embeddings.

## Configuration

### Basic Setup

Configure the Mock provider in your agent:

<<< @/../test/dummy/app/agents/providers/mock_agent.rb#agent{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/mock_examples_test.rb#mock_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/mock-provider-test.rb-test-basic-generation-with-mock-provider.md -->
:::

### Configuration File

Set up Mock provider in `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml#mock_anchor{yaml:line-numbers}

### Environment Variables

No environment variables are required for the Mock provider. It doesn't make external API calls.

## Provider-Specific Parameters

### Required Parameters

- **`service`** - Must be set to "Mock"
- **`model`** - Any string value (e.g., "mock-model") - not used functionally

### Optional Parameters

- **`instructions`** - System instructions (passed through but not enforced)
- **`stream`** - Enable streaming simulation (boolean, default: false)

The Mock provider accepts most standard parameters for compatibility but doesn't enforce them:
- `temperature`, `top_p`, `max_tokens` - Accepted but ignored
- `response_format` - Accepted but not validated or enforced
- Tool/function definitions - Accepted but tools won't be called

## Mock-Specific Features

### Pig Latin Responses

The Mock provider converts user messages to pig latin for predictable, deterministic output:

<<< @/../test/docs/providers/mock_examples_test.rb#mock_pig_latin_conversion{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/mock-provider-test.rb-test-converts-input-to-pig-latin.md -->
:::

**Conversion Rules:**
- Words starting with vowels: add "way" to the end ("apple" → "appleway")
- Words starting with consonants: move consonants to end and add "ay" ("hello" → "ellohay")
- Preserves punctuation and capitalization

### Offline Development

Work on your application without network connectivity:

<<< @/../test/docs/providers/mock_examples_test.rb#mock_no_api_calls{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/mock-provider-test.rb-test-works-offline-without-API-calls.md -->
:::

### Response Structure

Mock responses follow the same structure as real providers for seamless testing:

<<< @/../test/docs/providers/mock_examples_test.rb#mock_response_structure{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/mock-provider-test.rb-test-returns-proper-response-structure.md -->
:::

## Limitations

### No Real AI Responses

The Mock provider doesn't use actual AI models. Responses are deterministic pig latin transformations, not intelligent completions.

### No Tool Calling

The Mock provider doesn't support function/tool calling. Tools defined in agents using the Mock provider will not be invoked.

### Limited Structured Output

The Mock provider accepts structured output parameters but doesn't validate or enforce schemas. Responses will still be pig latin text, not structured JSON.

## Related Documentation

- [Providers Overview](/framework/providers)
- [Anthropic Provider](/providers/anthropic) - Anthropic Claude configuration
- [Configuration Guide](/getting_started#configuration)
- [Testing Guide](/framework/testing)
