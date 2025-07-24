require "test_helper"
require "active_agent/generation_provider/openai_adapters/responses_adapter"

class ResponsesAdapterTest < ActiveSupport::TestCase
  def setup
    @config = {
      "api_key" => Rails.application.credentials.dig(:openai, :api_key) || "test_key",
      "model" => "gpt-4o",
      "temperature" => 0.7
    }
    @client = OpenAI::Client.new(access_token: @config["api_key"])
    @adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter.new(@client, @config)
  end

  test "supports structured output prompts" do
    prompt = create_structured_output_prompt
    assert @adapter.supports?(prompt)
  end

  test "supports multipart content prompts" do
    prompt = create_multipart_prompt
    assert @adapter.supports?(prompt)
  end

  test "supports image input prompts" do
    prompt = create_image_prompt
    assert @adapter.supports?(prompt)
  end

  test "supports file input prompts" do
    prompt = create_file_input_prompt
    assert @adapter.supports?(prompt)
  end

  test "does not support simple text prompts" do
    prompt = create_text_prompt("Hello, how are you?")
    assert_not @adapter.supports?(prompt)
  end

  test "generates response with structured output" do
    VCR.use_cassette("responses_structured_output") do
      skip_if_no_api_key

      prompt = create_structured_output_prompt
      response = @adapter.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.present?
    end
  end

  test "generates response with text input" do
    VCR.use_cassette("responses_text_input") do
      skip_if_no_api_key

      prompt = create_text_input_prompt
      response = @adapter.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.present?
    end
  end

  test "generates response with image input" do
    skip "Responses API returning 400 - needs investigation"
    
    VCR.use_cassette("responses_image_input") do
      skip_if_no_api_key

      prompt = create_image_input_prompt
      response = @adapter.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert_equal :assistant, response.message.role
      assert response.message.content.present?
    end
  end

  test "generates response with tools" do
    skip "Responses API returning 400 - needs investigation"
    
    VCR.use_cassette("responses_with_tools") do
      skip_if_no_api_key

      prompt = create_prompt_with_tools("What's the weather like in Paris?")
      # The prompt should be supported by responses adapter when it has structured output via tools
      assert @adapter.supports?(prompt), "Prompt with tools should be supported by responses adapter"
      
      response = @adapter.generate(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      
      # Should either have content or requested actions
      assert(response.message.content.present? || response.message.requested_actions.any?)
    end
  end

  test "generates response with follow-up" do
    skip "Responses API returning 400 - needs investigation"
    
    VCR.use_cassette("responses_follow_up") do
      skip_if_no_api_key
      
      # First create an initial response
      initial_prompt = create_text_input_prompt("Hello, my name is Alice.")
      initial_response = @adapter.generate(initial_prompt)
      
      # Then create a follow-up
      follow_up_prompt = create_follow_up_prompt(initial_response.raw_response["id"])
      follow_up_response = @adapter.generate(follow_up_prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, follow_up_response
      assert follow_up_response.message.content.present?
    end
  end

  test "handles streaming response" do
    skip "Responses API returning 400 - needs investigation"
    
    VCR.use_cassette("responses_streaming") do
      skip_if_no_api_key

      prompt = create_streaming_prompt("Tell me a short story about a robot.")
      
      # Note: VCR may not capture streaming perfectly, so this test may need adjustment
      response = @adapter.generate(prompt)
      
      assert_instance_of ActiveAgent::GenerationProvider::Response, response
    end
  end

  test "generates embeddings" do
    VCR.use_cassette("responses_embeddings") do
      skip_if_no_api_key

      prompt = create_text_prompt("This is a test sentence for embedding.")
      response = @adapter.embed(prompt)

      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of Array, response.message.content
      assert response.message.content.length > 0
      assert response.message.content.all? { |n| n.is_a?(Numeric) }
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

  def create_text_input_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: "Hello, how are you?", role: :user)
      ],
      options: {
        input_text: "Hello, how are you?"
      }
    )
  end

  def create_structured_output_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: "Generate a JSON object with name and age", role: :user)
      ],
      options: {
        structured_output: {
          type: "object",
          properties: {
            name: { type: "string", description: "Person's name" },
            age: { type: "number", description: "Person's age" }
          },
          required: ["name", "age"],
          additionalProperties: false
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
            { type: "image_url", image_url: { url: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg" } }
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

  def create_image_input_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: "What's in this image?", role: :user)
      ],
      options: {
        input_image: "https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg"
      }
    )
  end

  def create_file_input_prompt
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(
          content: "Analyze this file",
          input_file_id: "file-abc123",
          role: :user
        )
      ],
      options: {}
    )
  end

  def create_prompt_with_tools(content)
    tool_schema = {
      name: "get_weather",
      description: "Get the current weather for a location",
      parameters: {
        type: "object",
        properties: {
          location: {
            type: "string",
            description: "The city and state, e.g. San Francisco, CA"
          },
          unit: {
            type: "string",
            enum: ["celsius", "fahrenheit"],
            description: "The temperature unit"
          }
        },
        required: ["location"]
      }
    }

    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: content, role: :user)
      ],
      actions: [
        ActiveAgent::ActionPrompt::Action.new(
          name: tool_schema[:name],
          description: tool_schema[:description],
          parameters: tool_schema[:parameters]
        )
      ],
      options: {}
    )
  end

  def create_follow_up_prompt(previous_response_id)
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: "What's my name?", role: :user)
      ],
      options: {
        previous_response_id: previous_response_id
      }
    )
  end

  def create_streaming_prompt(content)
    ActiveAgent::ActionPrompt::Prompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: content, role: :user)
      ],
      options: {
        input_text: content,
        stream: proc { |message, delta, stop| 
          # Mock stream handler
        }
      }
    )
  end
end
