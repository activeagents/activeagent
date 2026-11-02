---
title: Ollama Provider
description: Local LLM inference using Ollama, and the large open models Ollama serves from its cloud. Run Llama 3, Mistral, and Gemma locally without external APIs, or gpt-oss, Kimi and GLM through Ollama Cloud with one option and an API key.
---
# {{ $frontmatter.title }}

The Ollama provider enables local LLM inference using the Ollama platform. Run models like Llama 3, Mistral, and Gemma locally without sending data to external APIs, perfect for privacy-sensitive applications and development. The same provider reaches [Ollama Cloud](#ollama-cloud) — the large open models Ollama serves from ollama.com, metered per token — and lists and describes the models any Ollama host serves.

## Configuration

### Basic Setup

Configure Ollama in your agent:

<<< @/../test/dummy/app/agents/providers/ollama_agent.rb#agent{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/ollama-provider-test.rb-test-basic-generation-with-Ollama.md -->
:::

### Configuration File

Set up Ollama in `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml#ollama_anchor{yaml:line-numbers}

### Environment Variables

A local server needs no API key. The provider reads the same variables the `ollama` command does:

```bash
OLLAMA_HOST=http://localhost:11434   # the server; a bare origin is completed to its /v1 endpoint
OLLAMA_API_KEY=...                   # Ollama Cloud, or a remote server behind an authenticating proxy
```

`OLLAMA_HOST` is read the way `ollama` reads it: a scheme-less `host[:port]` is http on port 11434, `https://ollama.com` is the cloud, and an explicit path (`https://ai.example.com/ollama/v1`, a reverse proxy) is kept. A `host:` given to `generate_with` or in `config/active_agent.yml` wins over the variable. `OLLAMA_ACCESS_TOKEN` is read as `OLLAMA_API_KEY` is.

## Ollama Cloud

[Ollama Cloud](https://ollama.com/cloud) serves open models too large for most machines — `gpt-oss:120b`, `kimi-k3`, `glm-5.3`, `deepseek-v4-flash`, `qwen3.5:397b` and more — behind the same OpenAI-compatible API as a local server, metered per token. There are two ways to reach it, and the provider handles both.

**Directly**, with `cloud: true` and an API key (created at [ollama.com/settings/keys](https://ollama.com/settings/keys)), the model named as the cloud lists it:

<<< @/../test/dummy/app/agents/providers/ollama_cloud_agent.rb#agent{ruby:line-numbers}

The key comes from `OLLAMA_API_KEY` or `api_key:`; a request to the cloud without one fails before it is sent, with `ActiveAgent::Providers::Errors::AuthenticationFailed` naming what to set. `cloud: true` sends requests to `https://ollama.com/v1` unless a `host:` is given, so a proxy in front of the cloud keeps its address.

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_cloud_example{ruby:line-numbers}

In `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml#ollama_cloud_anchor{yaml:line-numbers}

**Through a local server** signed in to the cloud (`ollama signin`), nothing changes: the host is the local one, no key is needed, and the model carries the local server's cloud marker — `generate_with :ollama, model: "gpt-oss:120b-cloud"`. The provider knows that `gpt-oss:120b-cloud` and `glm-4.6:cloud` name the cloud's `gpt-oss:120b` and `glm-4.6` (`ActiveAgent::Providers::Ollama::Cloud.canonical_model`), which is how the dashboard prices them alike.

### Looking Up Models

`ActiveAgent::Providers::Ollama::Catalog` reads the models a host serves from the host's own API — `GET /api/tags` to list them, `POST /api/show` to describe one — for a local server and for Ollama Cloud alike. A listing says which models the cloud serves (listed by the cloud, or relayed to it by a signed-in local server); a description adds the capabilities and the context length.

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_model_lookup{ruby:line-numbers}

An agent's provider offers the same two reads for its own host: `provider.models` and `provider.model_info(name)`. A host with only the OpenAI-compatible API (a proxy in front of Ollama) is listed through `GET /v1/models`, which names models and nothing else. Failures are typed — `Catalog::ConnectionError`, `Catalog::AuthenticationError` for a refused key, `Catalog::NotFoundError` for a model the host does not serve — and the dashboard's Settings → Provider API Keys runs the same lookup as its connection test.

### Pricing on Traces and Evaluations

Ollama Cloud is metered per token, and the [dashboard](/framework/dashboard#scenario-evaluations) prices a model run under Ollama from the cloud's listing by the name the cloud uses: `gpt-oss:120b-cloud` through a local server and `gpt-oss:120b` through the cloud cost the same, and `deepseek-v4-flash` under Ollama is Ollama's price, not DeepSeek's. The rates come from RubyLLM's model registry (its `ollama_cloud` provider) when the host app loads RubyLLM, and from the same rows bundled in the dashboard otherwise, so a cloud model shows a `catalog` rate on traces, metrics and evaluation runs rather than a fallback guess. A model the cloud does not list — a local `qwen3:8b` — is priced as before. The connection test and the model pickers' `GET /api/provider_models?provider=ollama` carry each listed model's rate.

## Installing Ollama

### macOS/Linux

```bash
# Install Ollama
curl -fsSL https://ollama.ai/install.sh | sh

# Start Ollama service
ollama serve

# Pull a model
ollama pull llama3
```

### Docker

```bash
docker run -d -v ollama:/root/.ollama -p 11434:11434 --name ollama ollama/ollama
docker exec -it ollama ollama pull llama3
```

## Supported Models

Ollama supports a wide range of open-source models that run locally on your machine. For the complete list of available models, see [Ollama's Model Library](https://ollama.ai/library).

### Popular Models

| Model | Sizes | Context Window | Best For |
|-------|-------|----------------|----------|
| **llama3** | 8B, 70B | 8K tokens | General purpose reasoning |
| **mistral** | 7B | 32K tokens | Balanced performance |
| **gemma** | 2B, 7B | 8K tokens | Lightweight, efficient |
| **codellama** | 7B, 13B, 34B | 16K tokens | Code generation and analysis |
| **mixtral** | 8x7B | 32K tokens | High quality, mixture of experts |
| **phi** | 2.7B | 2K tokens | Fast, small footprint |
| **qwen** | 0.5B to 72B | 32K tokens | Multilingual support |
| **deepseek-r1** | 1.5B to 70B | 64K tokens | Advanced reasoning |

**Recommended model identifiers:**
- **llama3** - Best for general use and reasoning
- **codellama** - Best for code-related tasks
- **mistral** - Best for long context understanding

::: tip Quantized Models
Ollama offers quantized versions that reduce memory usage and increase speed with minimal quality loss. For example: `ollama pull qwen3:0.6b`
:::

### List Installed Models

```bash
# List all locally available models
ollama list

# Pull a new model
ollama pull llama3

# Remove a model
ollama rm llama3
```

## Provider-Specific Parameters

### Required Parameters

- **`model`** - Model name (e.g., "llama3", "mistral")

### Sampling Parameters

- **`temperature`** - Controls randomness (0.0 to 1.0)
- **`top_p`** - Nucleus sampling parameter (0.0 to 1.0)
- **`top_k`** - Top-k sampling parameter (integer ≥ 0)
- **`num_predict`** - Maximum tokens to generate
- **`seed`** - For reproducible outputs (integer)
- **`stop`** - Array of stop sequences

### System Configuration

- **`host`** - Ollama server URL (default: `http://localhost:11434`, or `OLLAMA_HOST`); a bare origin is completed to its `/v1` endpoint
- **`cloud`** - `true` sends requests to [Ollama Cloud](#ollama-cloud) and expects an API key
- **`api_key`** - Bearer token for Ollama Cloud or a remote server (default: `OLLAMA_API_KEY`)
- **`keep_alive`** - Keep model loaded in memory (e.g., "5m", "1h")
- **`timeout`** - Request timeout in seconds

### Advanced Options

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_advanced_options{ruby:line-numbers}

### Embeddings

- **`embedding_model`** - Embedding model name (e.g., "nomic-embed-text")
- **`host`** - Ollama server URL for embeddings

### Streaming

- **`stream`** - Enable streaming responses (boolean, default: false)

## Local Inference

Run models completely offline without external API calls. All inference happens on your machine without requiring an internet connection.

**Privacy Benefits:**
- All data stays on your machine
- No external API calls
- No internet connection required after model download
- Full control over your data

## Performance Optimization

### Model Loading

Keep models in memory for faster responses:

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_model_loading{ruby:line-numbers}

### Hardware Acceleration

Configure GPU usage for better performance:

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_gpu_configuration{ruby:line-numbers}

### Quantization

Use quantized models for faster inference with less memory:

```bash
# Pull quantized versions
ollama pull llama3:8b-q4_0  # 4-bit quantization
ollama pull llama3:8b-q5_1  # 5-bit quantization
```

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_quantized_model{ruby:line-numbers}

## Structured Output

Ollama does not have native structured output support. However, many models can generate JSON through careful prompting. For comprehensive structured output patterns, see the [Structured Output Documentation](/actions/structured_output).

### Limitations

- **No guaranteed JSON output** - Depends on model following instructions
- **No schema enforcement** - Cannot guarantee specific field requirements
- **Quality varies by model** - Llama 3, Mixtral, and Mistral work best
- **Requires validation** - Always parse and validate responses

::: tip
For applications requiring guaranteed schema conformance, use [OpenAI](/providers/open_ai#structured-output) with strict mode or [Anthropic](/providers/anthropic#emulated-json-object-support). For local processing, implement robust validation and error handling.
:::

## Embeddings

Generate embeddings locally using Ollama's embedding models. For comprehensive embedding usage patterns, see the [Embeddings Documentation](/actions/embeddings).

### Available Embedding Models

| Model | Dimensions | Best For |
|-------|------------|----------|
| **nomic-embed-text** | 768 | High-quality text embeddings |
| **mxbai-embed-large** | 1024 | Large embedding model |
| **all-minilm** | 384 | Lightweight embeddings |

## Error Handling

Ollama-specific error handling for connection failures and missing models. For comprehensive error handling strategies, see the [Error Handling Documentation](/agents/error_handling).

### Common Ollama Errors

- **`Errno::ECONNREFUSED`** - Ollama service not running (start with `ollama serve`)
- **`Net::OpenTimeout`** - Connection timeout
- **`ActiveAgent::GenerationError`** - Model not found or generation failure

### Example

<<< @/../test/docs/providers/ollama_examples_test.rb#ollama_error_handling{ruby:line-numbers}

## Best Practices

1. **Pre-pull models** - Download models before first use: `ollama pull llama3`
2. **Monitor memory usage** - Large models require significant RAM (8GB+ recommended)
3. **Use appropriate models** - Balance size, speed, and capability for your use case
4. **Keep models loaded** - Use `keep_alive` parameter for frequently used models
5. **Implement fallbacks** - Handle connection failures and missing models gracefully
6. **Use quantization** - Reduce memory usage and increase speed with quantized models
7. **Test locally** - Ensure models work in development before deployment
8. **Consider GPU** - Use GPU acceleration for better performance with larger models

## Related Documentation

- [Dashboard](/framework/dashboard) - Traces, metrics and evaluation costs, priced per model and provider
- [Streaming](/agents/streaming) - Real-time response streaming patterns
- [Embeddings Framework](/actions/embeddings) - Complete guide to embeddings
- [Configuration](/framework/configuration) - Global provider setup
- [Structured Output](/actions/structured_output) - Structured output patterns
- [Providers Overview](/providers) - Provider comparison
- [Configuration Guide](/getting_started#configuration) - Setup and configuration
- [Error Handling](/agents/error_handling) - Error handling strategies
- [Ollama Documentation](https://ollama.ai/docs) - Official Ollama docs
- [Ollama Model Library](https://ollama.ai/library) - Available models
- [Ollama Cloud](https://ollama.com/cloud) - The cloud's models and per-token pricing

