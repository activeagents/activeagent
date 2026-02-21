---
title: Embeddings
description: Generate vector embeddings from text to enable semantic search, clustering, and similarity comparison in your AI applications.
---
# {{ $frontmatter.title }}

Generate vector embeddings from text to enable semantic search, clustering, and similarity comparison.

## Quick Start

<<< @/../test/docs/actions/embeddings_examples_test.rb#quick_start{ruby:line-numbers}

## Basic Usage

Generate embeddings using `embed` with synchronous or asynchronous execution:

<<< @/../test/docs/actions/embeddings_examples_test.rb#direct_embedding{ruby:line-numbers}

<<< @/../test/docs/actions/embeddings_examples_test.rb#background_processing{ruby:line-numbers}

<<< @/../test/docs/actions/embeddings_examples_test.rb#multiple_inputs{ruby:line-numbers}

## Response Structure

Embedding responses contain the vector data:

<<< @/../test/docs/actions/embeddings_examples_test.rb#response_structure{ruby:line-numbers}

## Configuration

Configure the embedding provider using `embed_with`:

<<< @/../test/docs/actions/embeddings_examples_test.rb#basic_configuration{ruby:line-numbers}

### Mixing Providers

Use different providers for prompting and embeddings:

<<< @/../test/docs/actions/embeddings_examples_test.rb#mixing_providers{ruby:line-numbers}

This lets you choose the best provider for each task—for example, using Anthropic's Claude for reasoning while leveraging OpenAI's specialized embedding models.

### Provider-Specific Options

**OpenAI**

<<< @/../test/docs/actions/embeddings_examples_test.rb#openai_options{ruby:line-numbers}

**Ollama**

<<< @/../test/docs/actions/embeddings_examples_test.rb#ollama_configuration{ruby:line-numbers}

See [OpenAI Provider](/providers/open_ai) and [Ollama Provider](/providers/ollama) for more options.

## Callbacks

Process embeddings with before and after callbacks:

<<< @/../test/docs/actions/embeddings_examples_test.rb#embedding_callbacks{ruby:line-numbers}

See [Callbacks](/agents/callbacks) for more on callback functionality.

## Similarity Search

Compare text similarity using cosine similarity:

<<< @/../test/docs/actions/embeddings_examples_test.rb#cosine_similarity{ruby:line-numbers}

## Model Dimensions

Different models produce different embedding dimensions:

<<< @/../test/docs/actions/embeddings_examples_test.rb#model_dimensions{ruby:line-numbers}

<<< @/../test/docs/actions/embeddings_examples_test.rb#reducing_dimensions{ruby:line-numbers}

## Related Documentation

- [Agents](/agents) - Understanding the agent lifecycle
- [Actions](/actions) - Overview of agent capabilities
- [Generation](/agents/generation) - Understanding the generation workflow
- [Callbacks](/agents/callbacks) - Before and after embedding hooks
- [Configuration](/framework/configuration) - Configure embedding behavior
- [Testing](/framework/testing) - Test embedding functionality
- [OpenAI Provider](/providers/open_ai) - OpenAI embedding models
- [Ollama Provider](/providers/ollama) - Local embedding generation
- [RubyLLM Provider](/providers/ruby_llm) - Embeddings via RubyLLM's unified API
