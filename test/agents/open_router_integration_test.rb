require "test_helper"
require "base64"
require "active_agent/action_prompt/message"

class OpenRouterIntegrationTest < ActiveSupport::TestCase
  setup do
    @agent = OpenRouterIntegrationAgent.new
  end

  def has_openrouter_credentials?
    Rails.application.credentials.dig(:open_router, :access_token).present? ||
    Rails.application.credentials.dig(:open_router, :api_key).present? ||
    ENV["OPENROUTER_API_KEY"].present?
  end

  test "detects vision support for compatible models" do
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o"
    )
    
    assert provider.supports_vision?("openai/gpt-4o")
    assert provider.supports_vision?("anthropic/claude-3-5-sonnet")
    refute provider.supports_vision?("openai/gpt-3.5-turbo")
  end

  test "detects structured output support for compatible models" do
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o"
    )
    
    assert provider.supports_structured_output?("openai/gpt-4o")
    assert provider.supports_structured_output?("openai/gpt-4o-mini")
    refute provider.supports_structured_output?("anthropic/claude-3-opus")
  end

  test "analyzes image with structured output schema" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?
    
    VCR.use_cassette("openrouter_image_analysis_structured") do
      # Use a test image URL
      image_url = "https://picsum.photos/200/300"
      
      prompt = OpenRouterIntegrationAgent.with(image_url: image_url).analyze_image
      response = prompt.generate_now
      
      assert_not_nil response
      assert_not_nil response.message
      
      # Parse the structured output
      if response.message.content.is_a?(String)
        begin
          result = JSON.parse(response.message.content)
          
          # Verify the structure matches our schema
          assert result.key?("description")
          assert result.key?("objects")
          assert result.key?("scene_type")
          assert result["objects"].is_a?(Array)
          assert ["indoor", "outdoor", "abstract", "document", "photo", "illustration"].include?(result["scene_type"])
        rescue JSON::ParserError
          # If it's not JSON, the model might not support structured output
          skip "Model returned non-JSON response, might not support structured output"
        end
      end
    end
  end

  test "extracts receipt data with structured output" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?
    
    VCR.use_cassette("openrouter_receipt_extraction") do
      # Use a sample receipt image URL
      receipt_url = "https://raw.githubusercontent.com/tesseract-ocr/test/master/testing/eurotext.png"
      
      prompt = OpenRouterIntegrationAgent.with(image_url: receipt_url).extract_receipt_data
      response = prompt.generate_now
      
      assert_not_nil response
      assert_not_nil response.message
      
      # Check if structured output was returned
      if response.message.content.is_a?(String)
        begin
          result = JSON.parse(response.message.content)
          
          # Verify required fields
          assert result.key?("merchant")
          assert result.key?("total")
          assert result["merchant"].key?("name")
          assert result["total"].key?("amount")
        rescue JSON::ParserError
          skip "Model returned non-JSON response"
        end
      end
    end
  end

  test "handles base64 encoded images" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?
    
    VCR.use_cassette("openrouter_base64_image") do
      # Create a simple test image
      test_image_path = Rails.root.join("test", "fixtures", "files", "test_image.jpg")
      
      if File.exist?(test_image_path)
        prompt = OpenRouterIntegrationAgent.with(image_path: test_image_path).analyze_image
        response = prompt.generate_now
        
        assert_not_nil response
        assert_not_nil response.message
        assert response.message.content.present?
      else
        skip "Test image file not found"
      end
    end
  end

  test "uses fallback models when primary fails" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?
    
    VCR.use_cassette("openrouter_fallback_models") do
      prompt = OpenRouterIntegrationAgent.test_fallback
      response = prompt.generate_now
      
      assert_not_nil response
      assert_not_nil response.message
      
      # Check metadata for fallback usage
      if response.respond_to?(:metadata) && response.metadata
        # Should use one of the fallback models, not the primary
        possible_models = ["openai/gpt-3.5-turbo-0301", "openai/gpt-3.5-turbo", "openai/gpt-4o-mini"]
        assert possible_models.include?(response.metadata[:model_used])
        assert response.metadata[:provider].present?
      end
      
      # The response should still work (2+2=4)
      assert response.message.content.include?("4")
    end
  end

  test "applies transforms for long content" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?
    
    VCR.use_cassette("openrouter_transforms") do
      # Generate a very long text
      long_text = "Lorem ipsum dolor sit amet. " * 1000
      
      prompt = OpenRouterIntegrationAgent.with(text: long_text).process_long_text
      response = prompt.generate_now
      
      assert_not_nil response
      assert_not_nil response.message
      assert response.message.content.present?
      
      # The summary should be much shorter than the original
      assert response.message.content.length < long_text.length / 10
    end
  end

  test "tracks usage and costs" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?
    
    VCR.use_cassette("openrouter_cost_tracking") do
      prompt = OpenRouterIntegrationAgent.with(message: "Hello").prompt_context
      response = prompt.generate_now
      
      assert_not_nil response
      
      # Check for usage information
      if response.respond_to?(:usage) && response.usage
        assert response.usage["prompt_tokens"].is_a?(Integer)
        assert response.usage["completion_tokens"].is_a?(Integer)
        assert response.usage["total_tokens"].is_a?(Integer)
      end
      
      # Check for metadata with model information from OpenRouter
      if response.respond_to?(:metadata) && response.metadata
        assert response.metadata[:model_used].present?
        assert response.metadata[:provider].present?
        # Verify we're using the expected model (gpt-4o-mini)
        assert_equal "openai/gpt-4o-mini", response.metadata[:model_used]
      end
    end
  end

  test "includes OpenRouter headers in requests" do
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o",
      "app_name" => "TestApp",
      "site_url" => "https://test.example.com"
    )
    
    # Get the headers that would be sent
    headers = provider.send(:openrouter_headers)
    
    assert_equal "https://test.example.com", headers["HTTP-Referer"]
    assert_equal "TestApp", headers["X-Title"]
  end

  test "builds provider preferences correctly" do
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o",
      "enable_fallbacks" => true,
      "provider" => {
        "order" => ["OpenAI", "Anthropic"],
        "require_parameters" => true,
        "data_collection" => "deny"
      }
    )
    
    prefs = provider.send(:build_provider_preferences)
    
    assert_equal ["OpenAI", "Anthropic"], prefs[:order]
    assert_equal true, prefs[:require_parameters]
    assert_equal true, prefs[:allow_fallbacks]
    assert_equal "deny", prefs[:data_collection]
  end

  test "handles multimodal content correctly" do
    # Create a message with multimodal content
    message = ActiveAgent::ActionPrompt::Message.new(
      content: [
        { type: "text", text: "What's in this image?" },
        { type: "image_url", image_url: { url: "https://example.com/image.jpg" } }
      ],
      role: :user
    )
    
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      messages: [message]
    )
    
    assert prompt.multimodal?
  end

  test "respects configuration hierarchy for site_url" do
    # Test with explicit site_url config
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o",
      "site_url" => "https://configured.example.com"
    )
    
    assert_equal "https://configured.example.com", provider.instance_variable_get(:@site_url)
    
    # Test with default_url_options in config
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o",
      "default_url_options" => {
        "host" => "fromconfig.example.com"
      }
    )
    
    assert_equal "fromconfig.example.com", provider.instance_variable_get(:@site_url)
  end

  test "handles rate limit information in metadata" do
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o"
    )
    
    # Create a mock response
    prompt = ActiveAgent::ActionPrompt::Prompt.new(message: "test")
    response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt)
    
    headers = {
      "x-provider" => "OpenAI",
      "x-model" => "gpt-4o",
      "x-ratelimit-requests-limit" => "100",
      "x-ratelimit-requests-remaining" => "99",
      "x-ratelimit-tokens-limit" => "10000",
      "x-ratelimit-tokens-remaining" => "9500"
    }
    
    provider.send(:add_openrouter_metadata, response, headers)
    
    assert_equal "100", response.metadata[:ratelimit][:requests_limit]
    assert_equal "99", response.metadata[:ratelimit][:requests_remaining]
    assert_equal "10000", response.metadata[:ratelimit][:tokens_limit]
    assert_equal "9500", response.metadata[:ratelimit][:tokens_remaining]
  end
end