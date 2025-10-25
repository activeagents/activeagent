# OpenRouter Provider

The OpenRouter provider enables access to 200+ AI models from multiple providers (OpenAI, Anthropic, Google, Meta, and more) through a unified API. It offers intelligent model routing, automatic fallbacks, multimodal support, PDF processing, and cost optimization features.

## Configuration

### Basic Setup

Configure OpenRouter in your agent:

<<< @/../test/dummy/app/agents/providers/open_router_agent.rb#agent{ruby:line-numbers}

### Basic Usage Example

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_basic_example{ruby:line-numbers}

::: details Response Example
<!-- @include: @/parts/examples/open-router-provider-test.rb-test-basic-generation-with-OpenRouter.md -->
:::

### Configuration File

Set up OpenRouter credentials in `config/active_agent.yml`:

<<< @/../test/dummy/config/active_agent.yml#open_router_anchor{yaml:line-numbers}

### Environment Variables

Alternatively, use environment variables:

```bash
OPEN_ROUTER_API_KEY=your-api-key
# or
OPENROUTER_API_KEY=your-api-key
```

## Supported Models

OpenRouter provides access to 200+ models from multiple providers. For the complete list of available models and their capabilities, see [OpenRouter Models](https://openrouter.ai/models).

### Popular Models

| Provider | Model | Context Window | Best For |
|----------|-------|----------------|----------|
| **OpenAI** | openai/gpt-4o | 128K tokens | Vision, structured output, complex reasoning |
| **OpenAI** | openai/gpt-4o-mini | 128K tokens | Fast, cost-effective with vision support |
| **Anthropic** | anthropic/claude-3-5-sonnet | 200K tokens | Balanced performance, coding, analysis |
| **Anthropic** | anthropic/claude-3-opus | 200K tokens | Most capable Claude model |
| **Google** | google/gemini-pro-1.5 | 2M tokens | Very long context windows |
| **Meta** | meta-llama/llama-3.1-405b | 128K tokens | Open source, powerful reasoning |
| **Free** | qwen/qwen3-30b-a3b:free | 32K tokens | Free tier testing and development |

**Recommended model identifiers:**
- **openai/gpt-4o** - Best for vision tasks and structured output
- **anthropic/claude-3-5-sonnet** - Best for coding and complex analysis
- **google/gemini-pro-1.5** - Best for extremely long documents

::: tip Model Prefixes
OpenRouter uses provider prefixes (e.g., `openai/`, `anthropic/`) to route requests to the correct provider. This allows you to use the same model across different providers or switch between them easily.
:::

## Provider-Specific Parameters

### Required Parameters

- **`model`** - Model identifier (e.g., "openai/gpt-4o", default: "openrouter/auto")

### Sampling Parameters

- **`temperature`** - Controls randomness (0.0 to 2.0, default: varies by model)
- **`max_tokens`** - Maximum tokens to generate (minimum: 1)
- **`top_p`** - Nucleus sampling parameter (0.0 to 1.0)
- **`top_k`** - Top-k sampling parameter (integer ≥ 1)
- **`frequency_penalty`** - Penalize frequent tokens (-2.0 to 2.0)
- **`presence_penalty`** - Penalize new topics (-2.0 to 2.0)
- **`repetition_penalty`** - Control repetition (0.0 to 2.0)
- **`min_p`** - Minimum probability threshold (0.0 to 1.0)
- **`top_a`** - Top-a sampling parameter (0.0 to 1.0)
- **`seed`** - For deterministic outputs (integer)
- **`stop`** - Stop sequences (string or array)

### Tools & Functions

- **`tools`** - Array of tool definitions for function calling
- **`tool_choice`** - Control which tools can be used ("auto", "any", or specific tool)
- **`parallel_tool_calls`** - Allow parallel tool execution (boolean)

::: tip Tool Calling Support
Tool calling support varies by model. Most modern models (GPT-4o, Claude 3.5, Gemini Pro) support function calling. Check the [OpenRouter model documentation](https://openrouter.ai/models) for specific model capabilities.
:::

### Response Format

- **`response_format`** - Output format control (see [Structured Output](/actions/structured-output))

### Predicted Outputs

- **`prediction`** - Predicted output configuration for latency optimization (supported by compatible models)

### OpenRouter-Specific Features

- **`models`** (or `fallback_models`) - Array of fallback models for automatic failover
- **`route`** - Routing strategy ("fallback")
- **`transforms`** - Content transforms (e.g., ["middle-out"] for long context)
- **`provider`** - Provider preferences (see [Provider Preferences](#provider-preferences))
- **`user`** - Stable user identifier for cost tracking and analytics

### Client Configuration

- **`access_token`** - OpenRouter API key (also accepts `api_key`)
- **`uri_base`** - API endpoint (default: "https://openrouter.ai/api/v1")
- **`app_name`** - Application name for usage attribution
- **`site_url`** - Site URL for referral tracking and credits

### Streaming

- **`stream`** - Enable streaming responses (boolean, default: false)

## Model Routing & Fallbacks

OpenRouter provides intelligent model routing with automatic fallbacks when models are unavailable or requests fail.

### Automatic Fallbacks

Configure fallback models that will be tried in order if the primary model fails:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_fallback_agent{ruby:line-numbers}

**Fallback Behavior:**
- Models are tried in the order specified
- Automatic retry on rate limits or availability issues
- Seamless failover with no code changes needed
- Cost optimization by trying cheaper alternatives first

### Model Selection Strategies

Use the `route` parameter to control routing behavior:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_auto_routing_agent{ruby:line-numbers}

**Available Routes:**
- **`fallback`** - Try models in order until one succeeds

## Provider Preferences

Fine-tune which providers and configurations OpenRouter uses for your requests.

### Basic Provider Configuration

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_provider_preferences_agent{ruby:line-numbers}

### Provider Selection

Control which providers handle your requests:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_provider_selection_agent{ruby:line-numbers}

### Cost Optimization

Set maximum price constraints to control costs:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_cost_optimization_agent{ruby:line-numbers}

**Sorting Options:**
- **`price`** - Lowest cost providers first
- **`throughput`** - Highest throughput providers first
- **`latency`** - Lowest latency providers first

### Privacy & Data Collection

Control data collection and privacy settings:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_privacy_agent{ruby:line-numbers}

**Data Collection Options:**
- **`allow`** (default) - Allow providers that may store/train on data
- **`deny`** - Only use providers with strict no-data-retention policies

### Quantization Control

Filter providers by model quantization level:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_quantization_agent{ruby:line-numbers}

**Available Quantizations:**
- `int4`, `int8` - Lower precision, faster inference
- `fp4`, `fp6`, `fp8` - Mixed precision
- `fp16`, `bf16` - High precision
- `fp32` - Full precision
- `unknown` - Unspecified quantization

## Content Transforms

OpenRouter provides content transforms to optimize long-context handling.

### Middle-Out Compression

The `middle-out` transform automatically compresses the middle portion of long contexts while preserving the beginning and end:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_transforms_agent{ruby:line-numbers}

**Benefits:**
- Reduces token usage for long documents
- Preserves important context at start/end
- Lowers costs on long-context requests
- Maintains coherent summaries

## Cost Tracking & Analytics

OpenRouter provides detailed usage analytics when you configure tracking parameters.

### User Tracking

Track costs per user with the `user` parameter:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_user_tracking_agent{ruby:line-numbers}

### Application Attribution

Configure app tracking for referral credits:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_app_attribution_agent{ruby:line-numbers}

**Benefits:**
- Earn referral credits for traffic
- Track usage across applications
- Detailed cost breakdowns in OpenRouter dashboard
- Per-user and per-model analytics

## Multimodal Support

OpenRouter supports vision-capable models for image analysis and multimodal tasks.

### Image Analysis

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_vision_agent{ruby:line-numbers}

**Vision-Capable Models:**
- `openai/gpt-4o` - Best vision performance
- `openai/gpt-4o-mini` - Fast, cost-effective vision
- `anthropic/claude-3-5-sonnet` - Strong vision + reasoning
- `google/gemini-pro-vision` - Google's vision model

## PDF Processing

OpenRouter provides built-in PDF processing capabilities through plugins.

### PDF Document Analysis

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_pdf_agent{ruby:line-numbers}

**PDF Processing Engines:**
- **`pdf-text`** (free) - Text extraction from PDFs
- **`mistral-ocr`** ($2/1000 pages) - OCR for scanned documents
- **`native`** (input tokens) - Model's native PDF support

## Best Practices

### 1. Use Fallbacks for Reliability

Always configure fallback models for production systems:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_best_practice_fallbacks_agent{ruby:line-numbers}

### 2. Optimize Costs with Provider Preferences

Use cost-based sorting and price limits:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_best_practice_cost_agent{ruby:line-numbers}

### 3. Track Usage Per User

Enable detailed analytics:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_best_practice_tracking_agent{ruby:line-numbers}

### 4. Use Transforms for Long Content

Apply middle-out compression for documents:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_best_practice_transforms_agent{ruby:line-numbers}

### 5. Respect Privacy with Provider Settings

For sensitive data, use privacy-first providers:

<<< @/../test/docs/providers/open_router_examples_test.rb#openrouter_best_practice_privacy_agent{ruby:line-numbers}

## Related Documentation

- [Structured Output](/actions/structured-output) - Comprehensive structured output guide
- [Data Extraction Agent](/examples/data-extraction-agent) - Data extraction examples
- [Providers Overview](/providers) - Provider architecture
- [Configuration Guide](/framework/configuration) - General configuration
- [OpenRouter API Documentation](https://openrouter.ai/docs) - Official OpenRouter docs
- [OpenRouter Provider Routing](https://openrouter.ai/docs/provider-routing) - Advanced routing documentation
