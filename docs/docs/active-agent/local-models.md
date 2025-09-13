# Local Model Support

ActiveAgent supports running models locally using ONNX Runtime and Transformers, enabling you to:
- Run models offline without API calls
- Use open-source models from HuggingFace
- Load custom trained models
- Run on Apple Silicon (M1/M2/M3), NVIDIA GPUs, or CPU

## Installation

### For ONNX Runtime Support

Add to your Gemfile:

```ruby
gem 'onnxruntime'
gem 'informers'  # For HuggingFace model support
```

### For Transformers Support

Add to your Gemfile:

```ruby
gem 'transformers-ruby'
```

## Quick Start

### Using ONNX Models

<<< @/../test/dummy/app/agents/local_model_agent.rb#onnx_example {ruby:line-numbers}

### Using Transformer Models

<<< @/../test/dummy/app/agents/local_model_agent.rb#transformers_example {ruby:line-numbers}

### Generating Embeddings

<<< @/../test/dummy/app/agents/embedding_agent.rb#embedding_example {ruby:line-numbers}

## Configuration

### ONNX Runtime Configuration

<<< @/../test/dummy/config/active_agent.yml#onnx_runtime_anchor {yaml:line-numbers}

::: details Configuration Example Output
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-ONNX-Runtime-configuration-example.md -->
:::

### Transformers Configuration

<<< @/../test/dummy/config/active_agent.yml#transformers_anchor {yaml:line-numbers}

::: details Configuration Example Output
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Transformers-configuration-example.md -->
:::

### Embedding Models

<<< @/../test/dummy/config/active_agent.yml#onnx_embedding_anchor {yaml:line-numbers}

::: details Embedding Configuration Example
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Embedding-model-configuration-example.md -->
:::

## Model Sources

Models can be loaded from various sources:

### HuggingFace Hub (Auto-Download)

Models are automatically downloaded and cached from HuggingFace:

<<< @/../test/agents/local_models_documentation_test.rb#test_model_sources {ruby:line-numbers}

::: details Model Sources Configuration
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Model-source-configurations.md -->
:::

## Device Configuration

### Automatic Device Detection

<<< @/../test/agents/local_models_documentation_test.rb#test_device_detection {ruby:line-numbers}

::: details Device Detection Output
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Device-detection-logic.md -->
:::

### Apple Silicon Optimization

For M1/M2/M3 Macs, use Metal Performance Shaders:

<<< @/../test/agents/local_models_documentation_test.rb#test_apple_silicon_config {ruby:line-numbers}

::: details Apple Silicon Configuration
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Apple-Silicon-(M1/M2/M3)-optimized-configuration.md -->
:::

## Model Management

### Downloading Models

ActiveAgent provides rake tasks for managing models:

<<< @/../test/agents/local_models_documentation_test.rb#test_rake_tasks {ruby:line-numbers}

::: details Available Rake Tasks
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Rake-task-commands.md -->
:::

### List Available Models

```bash
bundle exec rake activeagent:models:list
```

This shows pre-configured models for both ONNX Runtime and Transformers.

### Download a Model

```bash
# From HuggingFace
bundle exec rake activeagent:models:download[huggingface,Xenova/gpt2]

# From GitHub
bundle exec rake activeagent:models:download[github,owner/repo/releases/download/v1.0/model.onnx]

# From URL
bundle exec rake activeagent:models:download[url,https://example.com/model.onnx]
```

### Setup Demo Models

```bash
bundle exec rake activeagent:models:setup_demo
```

This downloads recommended models for getting started quickly.

### Cache Management

```bash
# View cache information
bundle exec rake activeagent:models:cache_info

# Clear model cache
bundle exec rake activeagent:models:clear_cache
```

## Performance Optimization

### Model Caching

<<< @/../test/agents/local_models_documentation_test.rb#test_performance_settings {ruby:line-numbers}

::: details Performance Settings Example
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Performance-optimization-settings.md -->
:::

### Model Preloading

<<< @/../test/agents/local_models_documentation_test.rb#test_model_preloading {ruby:line-numbers}

::: details Preloading Configuration
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Model-preloading-on-application-start.md -->
:::

### Batch Processing

For better performance with multiple inputs:

<<< @/../test/agents/local_models_documentation_test.rb#test_batch_processing {ruby:line-numbers}

::: details Batch Processing Example
<!-- @include: @/parts/examples/local-models-documentation-test.rb-test-Batch-processing-example.md -->
:::

## Example Use Cases

### Semantic Search

Create embeddings for documents and search them:

<<< @/../test/dummy/app/agents/embedding_agent.rb#semantic_search {ruby:line-numbers}

### Local Chat Bot

Run a conversational AI locally:

<<< @/../test/dummy/app/agents/local_model_agent.rb#chat_bot {ruby:line-numbers}

### Sentiment Analysis

Analyze text sentiment without API calls:

<<< @/../test/dummy/app/agents/local_model_agent.rb#sentiment {ruby:line-numbers}

## Supported Model Types

### ONNX Runtime Provider
- **Text Generation**: GPT-2, GPT-Neo, CodeGen
- **Embeddings**: MiniLM, MPNet, BERT
- **Text2Text**: T5, BART
- **Question Answering**: DistilBERT, RoBERTa
- **Summarization**: BART, T5

### Transformers Provider
- **Text Generation**: GPT-2, DialoGPT, GPT-Neo
- **Embeddings**: BERT, RoBERTa, Sentence Transformers
- **Sentiment Analysis**: DistilBERT, RoBERTa
- **Translation**: MarianMT, OPUS-MT
- **Summarization**: BART, T5, Pegasus
- **Question Answering**: BERT, DistilBERT

## Troubleshooting

### Model Download Issues

If models fail to download from HuggingFace:
1. Check your internet connection
2. Verify the model name is correct
3. Set cache directory permissions: `chmod -R 755 storage/models`
4. Use a different model source (local file, URL)

### Memory Issues

For limited memory devices:
1. Use smaller models (distil* variants)
2. Reduce batch size
3. Use quantized models when available
4. Clear model cache between uses

### Performance Issues

1. Ensure you're using the correct device (GPU vs CPU)
2. Use smaller models for real-time applications
3. Implement model caching and preloading
4. Consider using ONNX models for better performance

## Testing

Test the providers:

```bash
# Test ONNX Runtime provider
bin/test test/generation_provider/onnx_runtime_provider_test.rb

# Test Transformers provider
bin/test test/generation_provider/transformers_provider_test.rb

# Test example agents
bin/test test/agents/local_model_agent_test.rb
```