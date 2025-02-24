# Active Agent: Generation Provider

This README provides information about the generation provider interfaces and implementations in the ActiveAgent library.

## Main Components

- Base class - Abstract class for implementing generation providers
- OpenAI Provider - Reference implementation using OpenAI's API
- Response class - Standardized response wrapper
- Module - For including generation provider functionality in agents

## Core Concepts

### Base Provider Class

The `ActiveAgent::GenerationProvider::Base` class defines the core interface that all providers must implement:

```ruby
def generate(prompt)
  raise NotImplementedError
end
```

### OpenAI Provider Implementation

The OpenAI provider shows how to implement a concrete generation provider:

- Handles authentication and client setup
- Implements prompt/completion generation
- Supports streaming responses
- Handles embeddings generation
- Manages context updates
- Processes tool/action calls

### Provider Features

- Configuration - Providers accept config options for API keys, models, etc
- Streaming - Optional streaming support for realtime responses
- Action handling - Support for function/tool calling
- Error handling - Standardized error handling via GenerationProviderError
- Context management - Tracks conversation context and message history

### Response Handling

The Response class wraps provider responses with a consistent interface:

```ruby
Response.new(
  prompt: prompt,    # Original prompt
  message: message,  # Generated response
  raw_response: raw  # Provider-specific response
)
```

## Usage Example

```ruby
# Configure provider
provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(
  "api_key" => ENV["OPENAI_API_KEY"],
  "model" => "gpt-4"
)

# Generate completion
response = provider.generate(prompt)

# Access response
response.message.content    # Generated text
response.raw_response      # Raw provider response
```

See the OpenAI provider implementation for a complete reference example.
