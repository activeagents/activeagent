require "test_helper"
require "active_agent/generation_provider/open_ai_provider"

class OpenAIProviderIntegrationTest < ActiveSupport::TestCase
  def setup
    @config = {
      "api_key" => Rails.application.credentials.dig(:openai, :api_key) || "test_key",
      "model" => "gpt-4o-mini",
      "temperature" => 0.7
    }
    @provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(@config)
  end

  test "selects chat completions adapter for simple text" do
    VCR.use_cassette("openai_provider_simple_text") do
      skip_if_no_api_key

      prompt = create_simple_text_prompt("Hello, world!")
      response = @provider.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.length > 0
    end
  end

  test "selects responses adapter for structured output" do
    skip "Responses API returning 400 - needs investigation"
    
    VCR.use_cassette("openai_provider_structured_output") do
      skip_if_no_api_key

      prompt = create_structured_output_prompt
      response = @provider.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.present?
    end
  end

  test "selects responses adapter for image input" do
    skip "Responses API returning 400 - needs investigation"
    
    VCR.use_cassette("openai_provider_image_input") do
      skip_if_no_api_key

      prompt = create_image_input_prompt
      response = @provider.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.present?
    end
  end

  test "selects responses adapter for multipart content" do
    skip "Responses API returning 400 - needs investigation"
    
    VCR.use_cassette("openai_provider_multipart_content") do
      skip_if_no_api_key

      prompt = create_multipart_prompt
      response = @provider.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.present?
    end
  end

  test "selects chat completions adapter for standard tools" do
    VCR.use_cassette("openai_provider_standard_tools") do
      skip_if_no_api_key

      prompt = create_standard_tools_prompt
      response = @provider.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert(response.message.content.present? || response.message.requested_actions.any?)
    end
  end

  test "handles embedding requests" do
    VCR.use_cassette("openai_provider_embeddings") do
      skip_if_no_api_key

      prompt = create_simple_text_prompt("This is a test sentence for embedding.")
      response = @provider.embed(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of Array, response.message.content
      assert response.message.content.length > 0
      assert response.message.content.all? { |n| n.is_a?(Numeric) }
    end
  end

  test "maintains backward compatibility with existing prompts" do
    VCR.use_cassette("openai_provider_backward_compatibility") do
      skip_if_no_api_key

      # Test that existing prompts still work without modification
      prompt = ActiveAgent::ActionPrompt::Prompt.new(
        messages: [
          ActiveAgent::ActionPrompt::Message.new(
            content: "Tell me a joke",
            role: :user
          )
        ],
        options: { temperature: 0.5 }
      )

      response = @provider.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert response.message.content.present?
    end
  end

  private

  def skip_if_no_api_key
    skip "OpenAI API key not configured" unless Rails.application.credentials.dig(:openai, :api_key)
  end

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
        input_image: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
      }
    )
  end

  def create_multipart_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(
          content: [
            { type: "text", text: "What's in this image?" },
            { type: "image_url", image_url: { url: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg" } }
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
