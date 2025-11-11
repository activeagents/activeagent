---
title: Ollama Provider
description: Local LLM inference using Ollama platform. Run Llama 3, Mistral, and Gemma locally without external APIs. Perfect for privacy-sensitive applications and development.
---
# {{ $frontmatter.title }}

The Ollama provider enables local LLM inference using the Ollama platform. Run models like Llama 3, Mistral, and Gemma locally without sending data to external APIs, perfect for privacy-sensitive applications and development.

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

No API keys required. Optionally configure connection settings:

```bash
OLLAMA_HOST=http://localhost:11434
OLLAMA_MODEL=llama3
```

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

- **`host`** - Ollama server URL (default: `http://localhost:11434`)
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

- [Streaming](/agents/streaming) - Real-time response streaming patterns
- [Embeddings Framework](/actions/embeddings) - Complete guide to embeddings
- [Configuration](/framework/configuration) - Global provider setup
- [Structured Output](/actions/structured_output) - Structured output patterns
- [Providers Overview](/providers) - Provider comparison
- [Configuration Guide](/getting_started#configuration) - Setup and configuration
- [Error Handling](/agents/error_handling) - Error handling strategies
- [Ollama Documentation](https://ollama.ai/docs) - Official Ollama docs
- [Ollama Model Library](https://ollama.ai/library) - Available models

