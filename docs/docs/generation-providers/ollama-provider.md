# Ollama Provider

The Ollama provider enables local LLM inference using the Ollama platform. Run models like Llama 3, Mistral, and Gemma locally without sending data to external APIs, perfect for privacy-sensitive applications and development.

## Configuration

### Basic Setup

Configure Ollama in your agent:

<<< @/../test/dummy/app/agents/ollama_agent.rb#snippet{ruby:line-numbers}

### Configuration File

Set up Ollama in `config/active_agent.yml`:

```yaml
development:
  ollama:
    host: http://localhost:11434  # Default Ollama host
    model: llama3
    temperature: 0.7
    
production:
  ollama:
    host: <%= ENV['OLLAMA_HOST'] || 'http://localhost:11434' %>
    model: llama3
    temperature: 0.3
```

### Environment Variables

Configure via environment:

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

### Popular Models

- **llama3** - Meta's Llama 3 (8B, 70B)
- **mistral** - Mistral 7B
- **gemma** - Google's Gemma (2B, 7B)
- **codellama** - Code-specialized Llama
- **mixtral** - Mixture of experts model
- **phi** - Microsoft's Phi-2
- **neural-chat** - Intel's fine-tuned model
- **qwen** - Alibaba's Qwen models

### List Available Models

```ruby
class OllamaAdmin < ApplicationAgent
  generate_with :ollama
  
  def list_models
    # Get list of installed models
    response = HTTParty.get("#{ollama_host}/api/tags")
    response["models"]
  end
  
  private
  
  def ollama_host
    Rails.configuration.active_agent.dig(:ollama, :host) || "http://localhost:11434"
  end
end
```

## Features

### Local Inference

Run models completely offline:

```ruby
class PrivateDataAgent < ApplicationAgent
  generate_with :ollama, model: "llama3"
  
  def process_sensitive_data
    @data = params[:sensitive_data]
    # Data never leaves your infrastructure
    prompt instructions: "Process this confidential information"
  end
end
```

### Model Switching

Easily switch between models:

```ruby
class MultiModelAgent < ApplicationAgent
  def code_review
    # Use specialized code model
    self.class.generate_with :ollama, model: "codellama"
    @code = params[:code]
    prompt
  end
  
  def general_chat
    # Use general purpose model
    self.class.generate_with :ollama, model: "llama3"
    @message = params[:message]
    prompt
  end
end
```

### Custom Models

Use fine-tuned or custom models:

```ruby
class CustomModelAgent < ApplicationAgent
  generate_with :ollama, model: "my-custom-model:latest"
  
  before_action :ensure_model_exists
  
  private
  
  def ensure_model_exists
    # Check if model is available
    models = fetch_available_models
    unless models.include?(generation_provider.model)
      raise "Model #{generation_provider.model} not found. Run: ollama pull #{generation_provider.model}"
    end
  end
end
```

### Streaming Responses

Stream responses for better UX:

```ruby
class StreamingOllamaAgent < ApplicationAgent
  generate_with :ollama, 
    model: "llama3",
    stream: true
  
  on_message_chunk do |chunk|
    # Handle streaming chunks
    Rails.logger.info "Chunk: #{chunk}"
    broadcast_to_client(chunk)
  end
  
  def chat
    prompt(message: params[:message])
  end
end
```

## Provider-Specific Parameters

### Model Parameters

- **`model`** - Model name (e.g., "llama3", "mistral")
- **`temperature`** - Controls randomness (0.0 to 1.0)
- **`top_p`** - Nucleus sampling
- **`top_k`** - Top-k sampling
- **`num_predict`** - Maximum tokens to generate
- **`stop`** - Stop sequences
- **`seed`** - For reproducible outputs

### System Configuration

- **`host`** - Ollama server URL (default: "http://localhost:11434")
- **`timeout`** - Request timeout in seconds
- **`keep_alive`** - Keep model loaded in memory

### Advanced Options

```ruby
class AdvancedOllamaAgent < ApplicationAgent
  generate_with :ollama,
    model: "llama3",
    options: {
      num_ctx: 4096,      # Context window size
      num_gpu: 1,         # Number of GPUs to use
      num_thread: 8,      # Number of threads
      repeat_penalty: 1.1, # Penalize repetition
      mirostat: 2,        # Mirostat sampling
      mirostat_tau: 5.0,  # Mirostat tau parameter
      mirostat_eta: 0.1   # Mirostat learning rate
    }
end
```

## Performance Optimization

### Model Loading

Keep models in memory for faster responses:

```ruby
class FastOllamaAgent < ApplicationAgent
  generate_with :ollama,
    model: "llama3",
    keep_alive: "5m"  # Keep model loaded for 5 minutes
  
  def quick_response
    @query = params[:query]
    prompt
  end
end
```

### Hardware Acceleration

Configure GPU usage:

```ruby
class GPUAgent < ApplicationAgent
  generate_with :ollama,
    model: "llama3",
    options: {
      num_gpu: -1,  # Use all available GPUs
      main_gpu: 0   # Primary GPU index
    }
end
```

### Quantization

Use quantized models for better performance:

```bash
# Pull quantized versions
ollama pull llama3:8b-q4_0  # 4-bit quantization
ollama pull llama3:8b-q5_1  # 5-bit quantization
```

```ruby
class EfficientAgent < ApplicationAgent
  # Use quantized model for faster inference
  generate_with :ollama, model: "llama3:8b-q4_0"
end
```

## Error Handling

Handle Ollama-specific errors:

```ruby
class RobustOllamaAgent < ApplicationAgent
  generate_with :ollama, model: "llama3"
  
  rescue_from Faraday::ConnectionFailed do |error|
    Rails.logger.error "Ollama connection failed: #{error.message}"
    render_ollama_setup_instructions
  end
  
  rescue_from ActiveAgent::GenerationError do |error|
    if error.message.include?("model not found")
      pull_model_and_retry
    else
      raise
    end
  end
  
  private
  
  def pull_model_and_retry
    system("ollama pull #{generation_provider.model}")
    retry
  end
  
  def render_ollama_setup_instructions
    "Ollama is not running. Start it with: ollama serve"
  end
end
```

## Testing

Test with Ollama locally:

```ruby
class OllamaAgentTest < ActiveSupport::TestCase
  setup do
    skip "Ollama not available" unless ollama_available?
  end
  
  test "generates response with local model" do
    response = OllamaAgent.with(
      message: "Hello"
    ).prompt_context.generate_now
    
    assert_not_nil response.message.content
    doc_example_output(response)
  end
  
  private
  
  def ollama_available?
    response = Net::HTTP.get_response(URI("http://localhost:11434/api/tags"))
    response.code == "200"
  rescue
    false
  end
end
```

## Development Workflow

### Local Development Setup

```ruby
# config/environments/development.rb
Rails.application.configure do
  config.active_agent = {
    ollama: {
      host: ENV['OLLAMA_HOST'] || 'http://localhost:11434',
      model: ENV['OLLAMA_MODEL'] || 'llama3',
      options: {
        num_ctx: 4096,
        temperature: 0.7
      }
    }
  }
end
```

### Docker Compose Setup

```yaml
# docker-compose.yml
version: '3.8'
services:
  ollama:
    image: ollama/ollama
    ports:
      - "11434:11434"
    volumes:
      - ollama_data:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  ollama_data:
```

## Best Practices

1. **Pre-pull models** - Download models before first use
2. **Monitor memory usage** - Large models require significant RAM
3. **Use appropriate models** - Balance size and capability
4. **Keep models loaded** - Use keep_alive for frequently used models
5. **Implement fallbacks** - Handle connection failures gracefully
6. **Use quantization** - Reduce memory usage and increase speed
7. **Test locally** - Ensure models work before deployment

## Ollama-Specific Considerations

### Privacy First

```ruby
class PrivacyFirstAgent < ApplicationAgent
  generate_with :ollama, model: "llama3"
  
  def process_pii
    @personal_data = params[:personal_data]
    
    # Data stays local - no external API calls
    Rails.logger.info "Processing PII locally with Ollama"
    
    prompt instructions: "Process this data privately"
  end
end
```

### Model Management

```ruby
class ModelManager
  def self.ensure_model(model_name)
    models = list_models
    unless models.include?(model_name)
      pull_model(model_name)
    end
  end
  
  def self.list_models
    response = HTTParty.get("http://localhost:11434/api/tags")
    response["models"].map { |m| m["name"] }
  end
  
  def self.pull_model(model_name)
    system("ollama pull #{model_name}")
  end
  
  def self.delete_model(model_name)
    HTTParty.delete("http://localhost:11434/api/delete", 
      body: { name: model_name }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
  end
end
```

### Deployment Considerations

```ruby
# Ensure Ollama is available in production
class ApplicationAgent < ActiveAgent::Base
  before_action :ensure_ollama_available, if: :using_ollama?
  
  private
  
  def using_ollama?
    generation_provider.is_a?(ActiveAgent::GenerationProvider::OllamaProvider)
  end
  
  def ensure_ollama_available
    HTTParty.get("#{ollama_host}/api/tags")
  rescue => e
    raise "Ollama is not available: #{e.message}"
  end
  
  def ollama_host
    Rails.configuration.active_agent.dig(:ollama, :host)
  end
end
```

## Related Documentation

- [Generation Provider Overview](/docs/framework/generation-provider)
- [Configuration Guide](/docs/getting-started#configuration)
- [Ollama Documentation](https://ollama.ai/docs)
- [OpenRouter Provider](/docs/generation-providers/open-router-provider) - For cloud alternative