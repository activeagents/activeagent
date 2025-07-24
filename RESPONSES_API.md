# OpenAI Responses API Support

This document demonstrates the comprehensive OpenAI Responses API support added to the ActiveAgent framework.

## Overview

The OpenAI Responses API is OpenAI's most advanced interface for generating model responses. It supports:

- **Text and multipart inputs**: Text, images, and files
- **Structured outputs**: JSON schemas with strict validation
- **Function calling**: Built-in tools and custom functions
- **Stateful interactions**: Follow-up messages using previous response IDs
- **Streaming**: Real-time response streaming

## Key Features Implemented

### 1. Multipart Content Support

The responses API supports multiple content types in a single request:

- `input_text`: Plain text content
- `input_image`: Image data (base64 encoded)
- `input_file`: File data with filename support

### 2. Structured Output with JSON Schema

Full support for OpenAI's structured output feature with:
- Named schemas
- Strict mode validation
- Custom descriptions
- Complex nested objects and arrays

### 3. Function Calling / Tools

Complete function calling support with:
- Custom tool definitions
- Parameter validation
- Response parsing
- Action handling

### 4. Follow-up Conversations

Stateful conversations using:
- `previous_response_id` parameter
- Conversation context preservation
- Multi-turn interactions

### 5. Streaming Support

Real-time streaming with:
- Delta content handling
- Progressive response building
- Error handling

## Usage Examples

### Basic Text Response

```ruby
provider = ActiveAgent::GenerationProvider::OpenAIProvider.new({
  "api_key" => "your-api-key",
  "model" => "gpt-4o"
})

message = ActiveAgent::ActionPrompt::Message.new(
  content: "Hello, how are you?",
  content_type: "text/plain",
  role: :user
)

prompt = ActiveAgent::ActionPrompt::Prompt.new(
  messages: [message],
  actions: []
)

response = provider.respond(prompt)
puts response.message.content
# => "Hello! I'm doing well, thank you for asking. How can I help you today?"
```

### Image Analysis

```ruby
image_message = ActiveAgent::ActionPrompt::Message.new(
  content: "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQ...",
  content_type: "input_image",
  role: :user
)

prompt = ActiveAgent::ActionPrompt::Prompt.new(
  messages: [image_message],
  actions: []
)

response = provider.respond(prompt)
puts response.message.content
# => "This image shows a beautiful sunset over the ocean..."
```

### File Analysis

```ruby
file_message = ActiveAgent::ActionPrompt::Message.new(
  content: "data:application/pdf;base64,JVBERi0xLjQKJc...",
  content_type: "input_file",
  file_name: "document.pdf",
  role: :user
)

prompt = ActiveAgent::ActionPrompt::Prompt.new(
  messages: [file_message],
  actions: []
)

response = provider.respond(prompt)
puts response.message.content
# => "This PDF document contains..."
```

### Multipart Input (Text + Image + File)

```ruby
text_message = ActiveAgent::ActionPrompt::Message.new(
  content: "Please analyze both the image and the PDF document",
  content_type: "text/plain",
  role: :user
)

image_message = ActiveAgent::ActionPrompt::Message.new(
  content: "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQ...",
  content_type: "input_image",
  role: :user
)

file_message = ActiveAgent::ActionPrompt::Message.new(
  content: "data:application/pdf;base64,JVBERi0xLjQKJc...",
  content_type: "input_file",
  file_name: "report.pdf",
  role: :user
)

prompt = ActiveAgent::ActionPrompt::Prompt.new(
  messages: [text_message, image_message, file_message],
  actions: []
)

response = provider.respond(prompt)
puts response.message.content
# => "Based on the image and PDF document you've shared..."
```

### Structured Output with JSON Schema

```ruby
json_schema = {
  type: "object",
  properties: {
    name: { type: "string" },
    age: { type: "integer" },
    skills: { 
      type: "array", 
      items: { type: "string" } 
    },
    experience: {
      type: "array",
      items: {
        type: "object",
        properties: {
          company: { type: "string" },
          role: { type: "string" },
          years: { type: "integer" }
        },
        required: ["company", "role"]
      }
    }
  },
  required: ["name", "age"]
}

message = ActiveAgent::ActionPrompt::Message.new(
  content: "Extract structured data from this resume: John Doe, 30 years old, Software Engineer...",
  content_type: "text/plain",
  role: :user
)

prompt = ActiveAgent::ActionPrompt::Prompt.new(
  options: { json_schema: json_schema },
  messages: [message],
  actions: []
)

response = provider.respond(prompt)
puts response.message.content
# => {
#      name: "John Doe",
#      age: 30,
#      skills: ["Ruby", "JavaScript", "Python"],
#      experience: [
#        { company: "Tech Corp", role: "Software Engineer", years: 3 }
#      ]
#    }
```

### Function Calling

```ruby
tools = [
  {
    "type" => "function",
    "name" => "get_weather",
    "description" => "Get current weather for a location",
    "parameters" => {
      "type" => "object",
      "properties" => {
        "location" => { 
          "type" => "string",
          "description" => "The city and state, e.g. San Francisco, CA" 
        },
        "unit" => { 
          "type" => "string", 
          "enum" => ["celsius", "fahrenheit"] 
        }
      },
      "required" => ["location"]
    }
  }
]

message = ActiveAgent::ActionPrompt::Message.new(
  content: "What's the weather in Paris?",
  content_type: "text/plain",
  role: :user
)

prompt = ActiveAgent::ActionPrompt::Prompt.new(
  messages: [message],
  actions: tools
)

response = provider.respond(prompt)

if response.message.action_requested
  action = response.message.requested_actions.first
  puts "Function to call: #{action.name}"
  puts "Parameters: #{action.params}"
  # => Function to call: get_weather
  # => Parameters: {"location"=>"Paris"}
end
```

### Follow-up Conversations

```ruby
# First interaction
first_message = ActiveAgent::ActionPrompt::Message.new(
  content: "My name is Alice",
  content_type: "text/plain",
  role: :user
)

first_prompt = ActiveAgent::ActionPrompt::Prompt.new(
  messages: [first_message],
  actions: []
)

first_response = provider.respond(first_prompt)
response_id = first_response.raw_response["id"]

# Follow-up interaction
followup_message = ActiveAgent::ActionPrompt::Message.new(
  content: "What's my name?",
  content_type: "text/plain",
  role: :user
)

followup_prompt = ActiveAgent::ActionPrompt::Prompt.new(
  options: { previous_response_id: response_id },
  messages: [followup_message],
  actions: []
)

followup_response = provider.respond(followup_prompt)
puts followup_response.message.content
# => "Your name is Alice!"
```

### Streaming Responses

```ruby
message = ActiveAgent::ActionPrompt::Message.new(
  content: "Write a short story about AI",
  content_type: "text/plain",
  role: :user
)

prompt = ActiveAgent::ActionPrompt::Prompt.new(
  options: { stream: true },
  messages: [message],
  actions: []
)

provider.respond(prompt) do |chunk_message, new_content|
  print new_content if new_content
  $stdout.flush
end
```

## API Compatibility

This implementation is fully compatible with:

- OpenAI Responses API v1
- Ruby OpenAI gem v8.1.0+
- All OpenAI models that support the responses API (gpt-4o, gpt-4o-mini, etc.)

## Testing

Comprehensive test coverage includes:

- ✅ Text input/output
- ✅ Image input (base64 encoded)
- ✅ File input with filename support
- ✅ Multipart content (text + image + file)
- ✅ Structured output with JSON schema
- ✅ Function calling / tools
- ✅ Follow-up conversations
- ✅ Streaming responses
- ✅ Error handling
- ✅ Content type validation

## Integration with ActiveAgent Framework

The responses API integrates seamlessly with the existing ActiveAgent framework:

- Uses the same `Message` and `Prompt` classes
- Supports the same configuration options
- Compatible with existing agents and workflows
- Maintains backward compatibility with the chat API

## Performance and Reliability

- Robust error handling for malformed responses
- Graceful fallbacks for unsupported content types
- Efficient streaming implementation
- Memory-conscious large file handling
- Comprehensive logging and debugging support
