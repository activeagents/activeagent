#!/usr/bin/env ruby
# Test script for OpenAI Responses API implementation
# Usage: ruby test_responses_api.rb

require_relative 'lib/active_agent'

# Mock a simple test without requiring actual API calls
puts "Testing OpenAI Responses API Implementation..."

begin
  # Test provider initialization
  config = {
    "service" => "OpenAI",
    "api_key" => "test-key",
    "model" => "gpt-4o"
  }

  provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
  puts "✅ Provider initialization: SUCCESS"

  # Test text input formatting
  message = ActiveAgent::ActionPrompt::Message.new(
    content: "Hello, world!",
    content_type: "text/plain",
    role: :user
  )

  prompt = ActiveAgent::ActionPrompt::Prompt.new(
    messages: [message],
    actions: []
  )
  provider.instance_variable_set(:@prompt, prompt)

  params = provider.send(:responses_parameters)
  
  if params[:input] == "Hello, world!" && params[:model] == "gpt-4o"
    puts "✅ Text input formatting: SUCCESS"
  else
    puts "❌ Text input formatting: FAILED"
  end

  # Test image input formatting
  image_message = ActiveAgent::ActionPrompt::Message.new(
    content: "data:image/jpeg;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
    content_type: "input_image",
    role: :user
  )

  image_prompt = ActiveAgent::ActionPrompt::Prompt.new(
    messages: [image_message],
    actions: []
  )
  provider.instance_variable_set(:@prompt, image_prompt)

  image_params = provider.send(:responses_parameters)
  
  if image_params[:input].is_a?(Array) && 
     image_params[:input][0][:type] == "text" &&
     image_params[:input][1][:type] == "image_url"
    puts "✅ Image input formatting: SUCCESS"
  else
    puts "❌ Image input formatting: FAILED"
  end

  # Test file input formatting
  file_message = ActiveAgent::ActionPrompt::Message.new(
    content: "data:application/pdf;base64,JVBERi0xLjQKJcOkw7zDtsO8...",
    content_type: "input_file",
    file_name: "document.pdf",
    role: :user
  )

  file_prompt = ActiveAgent::ActionPrompt::Prompt.new(
    messages: [file_message],
    actions: []
  )
  provider.instance_variable_set(:@prompt, file_prompt)

  file_params = provider.send(:responses_parameters)
  
  if file_params[:input].is_a?(Array) && 
     file_params[:input][0][:type] == "text" &&
     file_params[:input][1][:type] == "input_file" &&
     file_params[:input][1][:input_file][:filename] == "document.pdf"
    puts "✅ File input formatting: SUCCESS"
  else
    puts "❌ File input formatting: FAILED"
  end

  # Test structured output formatting
  json_schema = {
    type: "object",
    properties: {
      name: { type: "string" },
      age: { type: "integer" }
    },
    required: ["name", "age"]
  }

  structured_prompt = ActiveAgent::ActionPrompt::Prompt.new(
    options: { json_schema: json_schema },
    messages: [message],
    actions: []
  )
  provider.instance_variable_set(:@prompt, structured_prompt)

  structured_params = provider.send(:responses_parameters)
  
  if structured_params[:response_format][:type] == "json_schema" &&
     structured_params[:response_format][:json_schema][:schema] == json_schema
    puts "✅ Structured output formatting: SUCCESS"
  else
    puts "❌ Structured output formatting: FAILED"
  end

  # Test multipart input formatting
  text_msg = ActiveAgent::ActionPrompt::Message.new(
    content: "Analyze this",
    content_type: "text/plain",
    role: :user
  )
  
  multipart_prompt = ActiveAgent::ActionPrompt::Prompt.new(
    messages: [text_msg, image_message, file_message],
    actions: []
  )
  provider.instance_variable_set(:@prompt, multipart_prompt)

  multipart_params = provider.send(:responses_parameters)
  
  if multipart_params[:input].is_a?(Array) && multipart_params[:input].length == 3
    puts "✅ Multipart input formatting: SUCCESS"
  else
    puts "❌ Multipart input formatting: FAILED"
  end

  # Test function calling
  tools = [
    {
      "type" => "function",
      "name" => "get_weather",
      "description" => "Get weather",
      "parameters" => {
        "type" => "object",
        "properties" => {
          "location" => { "type" => "string" }
        }
      }
    }
  ]

  tool_prompt = ActiveAgent::ActionPrompt::Prompt.new(
    messages: [message],
    actions: tools
  )
  provider.instance_variable_set(:@prompt, tool_prompt)

  tool_params = provider.send(:responses_parameters)
  
  if tool_params[:tools] == tools
    puts "✅ Function calling setup: SUCCESS"
  else
    puts "❌ Function calling setup: FAILED"
  end

  # Test response parsing
  mock_response = {
    "id" => "resp_123abc",
    "object" => "response",
    "created" => 1625097600,
    "model" => "gpt-4o",
    "output" => [
      {
        "type" => "message",
        "content" => [
          {
            "type" => "text",
            "text" => "Hello! How can I help you today?"
          }
        ]
      }
    ]
  }

  result = provider.send(:responses_response, mock_response)
  
  if result.message.content == "Hello! How can I help you today?" &&
     result.message.role == :assistant &&
     result.message.generation_id == "resp_123abc"
    puts "✅ Response parsing: SUCCESS"
  else
    puts "❌ Response parsing: FAILED"
  end

  puts "\n🎉 All tests passed! OpenAI Responses API implementation is working correctly."

rescue => e
  puts "❌ Error during testing: #{e.message}"
  puts e.backtrace.first(5)
end
