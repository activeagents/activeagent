require "test_helper"
require "active_agent/generation_provider/open_ai_provider"

class OpenAIAdapterSelectionTest < ActiveSupport::TestCase
  def setup
    @config = {
      "api_key" => "test_key",
      "model" => "gpt-4o-mini",
      "temperature" => 0.7
    }
    @provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(@config)
  end

  test "selects chat completions adapter for simple text prompts" do
    prompt = create_simple_text_prompt("Hello, world!")
    
    # Use reflection to test adapter selection
    selected_adapter = @provider.send(:select_adapter, prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::OpenAIAdapters::ChatCompletionsAdapter, selected_adapter
  end

  test "selects responses adapter for structured output prompts" do
    prompt = create_structured_output_prompt
    
    # Use reflection to test adapter selection
    selected_adapter = @provider.send(:select_adapter, prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter, selected_adapter
  end

  test "selects responses adapter for multipart content prompts" do
    prompt = create_multipart_prompt
    
    # Use reflection to test adapter selection
    selected_adapter = @provider.send(:select_adapter, prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter, selected_adapter
  end

  test "selects responses adapter for image input prompts" do
    prompt = create_image_input_prompt
    
    # Use reflection to test adapter selection
    selected_adapter = @provider.send(:select_adapter, prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter, selected_adapter
  end

  test "selects chat completions adapter for standard tool prompts" do
    prompt = create_standard_tools_prompt
    
    # Use reflection to test adapter selection
    selected_adapter = @provider.send(:select_adapter, prompt)
    
    assert_instance_of ActiveAgent::GenerationProvider::OpenAIAdapters::ChatCompletionsAdapter, selected_adapter
  end

  test "chat completions adapter supports simple text prompts" do
    prompt = create_simple_text_prompt("Hello")
    adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ChatCompletionsAdapter.new(nil, @config)
    
    assert adapter.supports?(prompt)
  end

  test "chat completions adapter does not support structured output prompts" do
    prompt = create_structured_output_prompt
    adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ChatCompletionsAdapter.new(nil, @config)
    
    assert_not adapter.supports?(prompt)
  end

  test "responses adapter supports structured output prompts" do
    prompt = create_structured_output_prompt
    adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter.new(nil, @config)
    
    assert adapter.supports?(prompt)
  end

  test "responses adapter supports multipart content prompts" do
    prompt = create_multipart_prompt
    adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter.new(nil, @config)
    
    assert adapter.supports?(prompt)
  end

  test "responses adapter does not support simple text prompts" do
    prompt = create_simple_text_prompt("Hello")
    adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter.new(nil, @config)
    
    assert_not adapter.supports?(prompt)
  end

  private

  def create_simple_text_prompt(content)
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: content, role: :user)
      ],
      options: {}
    )
  end

  def create_structured_output_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(
          content: "Generate a person object with name and age",
          role: :user
        )
      ],
      options: {
        structured_output: {
          type: "object",
          properties: {
            name: { type: "string", description: "Person's name" },
            age: { type: "number", description: "Person's age" }
          },
          required: ["name", "age"]
        }
      }
    )
  end

  def create_image_input_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(
          content: "What do you see in this image?",
          role: :user
        )
      ],
      options: {
        input_image: "https://example.com/image.jpg"
      }
    )
  end

  def create_multipart_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(
          content: [
            { type: "text", text: "What's in this image?" },
            { type: "image_url", image_url: { url: "https://example.com/image.jpg" } }
          ],
          role: :user
        )
      ],
      options: {}
    )
  end

  def create_standard_tools_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(
          content: "What's the weather like in New York?",
          role: :user
        )
      ],
      actions: [
        {
          type: "function",
          function: {
            name: "get_weather",
            description: "Get the current weather",
            parameters: {
              type: "object",
              properties: {
                location: { type: "string", description: "The city name" }
              },
              required: ["location"]
            }
          }
        }
      ],
      options: {}
    )
  end
end
