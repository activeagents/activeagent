# Local Model Support for ActiveAgent

ActiveAgent now supports running models locally using ONNX Runtime and Transformers, enabling you to:
- Run models offline without API calls
- Use open-source models from HuggingFace
- Load custom trained models
- Run on Apple Silicon (M1/M2/M3), NVIDIA GPUs, or CPU

## Installation

### For ONNX Runtime Support

```bash
# Install ONNX Runtime gem
gem 'onnxruntime'

# For HuggingFace model support with Informers
gem 'informers'
```

### For Transformers Support

```bash
# Install Transformers Ruby gem
gem 'transformers-ruby'
```

## Quick Start

### 1. Using ONNX Models

```ruby
class MyAgent < ApplicationAgent
  # Configure to use ONNX Runtime with a HuggingFace model
  generate_with({
    "service" => "OnnxRuntime",
    "model_type" => "generation",
    "model" => "Xenova/gpt2",  # Auto-downloads from HuggingFace
    "task" => "text-generation",
    "max_tokens" => 50
  })
  
  def generate_text
    prompt message: params[:input]
  end
end
```

### 2. Using Transformer Models

```ruby
class MyAgent < ApplicationAgent
  # Configure to use Transformers
  generate_with({
    "service" => "Transformers",
    "model_type" => "generation",
    "model" => "microsoft/DialoGPT-small",
    "task" => "text-generation",
    "device" => "mps"  # Use Apple Silicon GPU
  })
  
  def chat
    prompt message: params[:message]
  end
end
```

### 3. Generating Embeddings

```ruby
class EmbeddingAgent < ApplicationAgent
  # Configure for embeddings
  generate_with({
    "service" => "OnnxRuntime",
    "model_type" => "embedding",
    "model" => "Xenova/all-MiniLM-L6-v2",
    "use_informers" => true
  })
  
  def create_embedding
    embed prompt: params[:text]  # Note: use 'embed' instead of 'prompt'
  end
end
```

## Model Sources

### 1. HuggingFace Hub (Auto-Download)

Models are automatically downloaded and cached:

```ruby
{
  "service" => "OnnxRuntime",
  "model" => "Xenova/gpt2",  # HuggingFace model ID
  "model_source" => "huggingface",
  "cache_dir" => Rails.root.join("tmp/models").to_s
}
```

### 2. Local File System

Use pre-downloaded models:

```ruby
{
  "service" => "OnnxRuntime",
  "model_type" => "custom",
  "model_source" => "local",
  "model_path" => "/path/to/model.onnx",
  "tokenizer_path" => "/path/to/tokenizer.json"
}
```

### 3. Active Storage

Load models from Rails Active Storage:

```ruby
model_record = Model.find(params[:model_id])
model_path = download_from_active_storage(model_record.file)

{
  "service" => "OnnxRuntime",
  "model_type" => "custom",
  "model_source" => "active_storage",
  "model_path" => model_path
}
```

### 4. URL Download

Download models from URLs:

```ruby
{
  "service" => "OnnxRuntime",
  "model_type" => "custom",
  "model_source" => "url",
  "model_url" => "https://example.com/models/my_model.onnx"
}
```

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

## Device Configuration

### Automatic Device Detection

```ruby
def detect_device
  if cuda_available?
    "cuda"
  elsif mps_available?
    "mps"  # Apple Silicon
  else
    "cpu"
  end
end
```

### Manual Device Selection

```ruby
{
  "service" => "Transformers",
  "device" => "mps"  # Options: "cuda", "mps", "cpu"
}
```

## Performance Optimization

### 1. Model Caching

Models are automatically cached after first download:

```ruby
ENV["ONNX_MODEL_CACHE"] = Rails.root.join("storage/models/onnx").to_s
ENV["TRANSFORMERS_CACHE"] = Rails.root.join("storage/models/transformers").to_s
```

### 2. Model Preloading

Preload models on application start:

```ruby
# config/initializers/local_models.rb
Rails.application.config.after_initialize do
  ActiveAgent::ModelPreloader.preload_models([
    :onnx_embeddings,
    :transformers_sentiment
  ])
end
```

### 3. Batch Processing

Process multiple inputs efficiently:

```ruby
def batch_embed
  texts = params[:texts]
  embeddings = texts.map { |text| embed(prompt: text) }
end
```

## Example Use Cases

### Semantic Search

```ruby
class SearchAgent < ApplicationAgent
  generate_with({
    "service" => "OnnxRuntime",
    "model_type" => "embedding",
    "model" => "Xenova/all-MiniLM-L6-v2"
  })
  
  def search
    query_embedding = embed(prompt: params[:query])
    
    # Compare with document embeddings
    results = documents.map do |doc|
      doc_embedding = embed(prompt: doc.content)
      similarity = cosine_similarity(query_embedding, doc_embedding)
      { document: doc, score: similarity }
    end
    
    results.sort_by { |r| -r[:score] }.first(10)
  end
end
```

### Multi-Language Support

```ruby
class TranslationAgent < ApplicationAgent
  def translate
    # Dynamically select translation model
    lang_pair = "#{params[:from]}-#{params[:to]}"
    
    generate_with({
      "service" => "Transformers",
      "model_type" => "translation",
      "model" => "Helsinki-NLP/opus-mt-#{lang_pair}"
    })
    
    prompt message: params[:text]
  end
end
```

### Local Chat Bot

```ruby
class LocalChatBot < ApplicationAgent
  generate_with({
    "service" => "Transformers",
    "model" => "microsoft/DialoGPT-medium",
    "device" => "mps",  # Use Apple Silicon
    "temperature" => 0.8,
    "max_tokens" => 100
  })
  
  def chat
    prompt messages: conversation_history
  end
end
```

## Demo Configuration for M1 MacBook Pro

```ruby
# Optimized for Apple Silicon
{
  "service" => "Transformers",
  "model" => "distilgpt2",  # Smaller model for demo
  "device" => "mps",  # Metal Performance Shaders
  "task" => "text-generation",
  "max_tokens" => 50,
  "temperature" => 0.7
}
```

## Demo Configuration for Jetson Nano

```ruby
# Optimized for Jetson Nano (ARM + CUDA)
{
  "service" => "OnnxRuntime",
  "model_type" => "generation",
  "model" => "Xenova/distilgpt2",  # Smaller model
  "device" => "cuda",  # Use Jetson's GPU
  "max_tokens" => 30,
  "temperature" => 0.7
}
```

## Troubleshooting

### Model Download Issues

If models fail to download from HuggingFace:

1. Check your internet connection
2. Verify the model name is correct
3. Set cache directory permissions: `chmod -R 755 tmp/models`
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

```ruby
# Test ONNX Runtime provider
rails test test/generation_provider/onnx_runtime_provider_test.rb

# Test Transformers provider
rails test test/generation_provider/transformers_provider_test.rb

# Test example agents
rails test test/dummy/test/agents/local_model_agent_test.rb
```

## Contributing

To add support for new model types:

1. Extend the appropriate provider class
2. Add model type handling in the `generate` method
3. Implement response handling
4. Add tests
5. Document the new model type

## License

Same as ActiveAgent - MIT License