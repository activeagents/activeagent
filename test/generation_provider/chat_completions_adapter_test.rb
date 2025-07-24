require "test_helper"
require "active_agent/generation_provider/openai_adapters/chat_completions_adapter"

class ChatCompletionsAdapterTest < ActiveSupport::TestCase
  def setup
    @config = {
      "api_key" => Rails.application.credentials.dig(:openai, :api_key) || "test_key",
      "model" => "gpt-4o-mini",
      "temperature" => 0.7
    }
    @client = OpenAI::Client.new(access_token: @config["api_key"])
    @adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ChatCompletionsAdapter.new(@client, @config)
  end

  test "supports standard text prompts" do
    prompt = create_text_prompt("Hello, how are you?")
    assert @adapter.supports?(prompt)
  end

  test "does not support structured output prompts" do
    prompt = create_structured_output_prompt
    assert_not @adapter.supports?(prompt)
  end

  test "does not support multipart content prompts" do
    prompt = create_multipart_prompt
    assert_not @adapter.supports?(prompt)
  end

  test "does not support image input prompts" do
    prompt = create_image_prompt
    assert_not @adapter.supports?(prompt)
  end

  test "generates response for simple text prompt" do
    VCR.use_cassette("chat_completions_simple_text") do
      skip_if_no_api_key

      prompt = create_text_prompt("Say hello world")
      response = @adapter.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.length > 0
    end
  end

  test "generates response with tools" do
    VCR.use_cassette("chat_completions_with_tools") do
      skip_if_no_api_key

      prompt = create_prompt_with_tools("What's the weather like in Paris?")
      response = @adapter.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      
      # Should either have content or requested actions
      assert(response.message.content.present? || response.message.requested_actions.any?)
    end
  end

  test "generates embeddings" do
    VCR.use_cassette("chat_completions_embeddings") do
      skip_if_no_api_key

      prompt = create_text_prompt("This is a test sentence for embedding.")
      response = @adapter.embed(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of Array, response.message.content
      assert response.message.content.length > 0
      assert response.message.content.all? { |n| n.is_a?(Numeric) }
    end
  end

  test "handles streaming response" do
    VCR.use_cassette("chat_completions_streaming") do
      skip_if_no_api_key

      prompt = create_streaming_prompt("Tell me a short story about a robot.")
      chunks = []
      
      # Note: VCR may not capture streaming perfectly, so this test may need adjustment
      response = @adapter.generate(prompt)
      
      assert_instance_of ActiveAgent::GenerationProvider::Response, response
    end
  end

  private

  def skip_if_no_api_key
    skip "OpenAI API key not configured" unless Rails.application.credentials.dig(:openai, :api_key)
  end

  def create_text_prompt(content)
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
        ActiveAgent::ActionPrompt::Message.new(content: "Generate a JSON object", role: :user)
      ],
      options: {
        structured_output: {
          type: "object",
          properties: {
            name: { type: "string" },
            age: { type: "number" }
          }
        }
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

  def create_image_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(
          content: "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD...",
          content_type: "image_url",
          role: :user
        )
      ],
      options: {}
    )
  end

  def create_prompt_with_tools(content)
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: content, role: :user)
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

  def create_streaming_prompt(content)
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: content, role: :user)
      ],
      options: {
        stream: proc { |message, delta, stop| 
          # Mock stream handler
        }
      }
    )
  end
end
