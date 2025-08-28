require "test_helper"
require "base64"
require "active_agent/action_prompt/message"

class OpenRouterIntegrationTest < ActiveSupport::TestCase
  setup do
    @agent = OpenRouterIntegrationAgent.new
  end

  test "analyzes image with structured output schema" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_image_analysis_structured") do
      # Use the sales chart image URL for structured analysis
      image_url = "https://raw.githubusercontent.com/activeagents/activeagent/refs/heads/main/test/fixtures/images/sales_chart.png"

      prompt = OpenRouterIntegrationAgent.with(image_url: image_url).analyze_image
      response = prompt.generate_now

      assert_not_nil response
      assert_not_nil response.message

      # Parse the structured output
      if response.message.content.is_a?(String)
      # When output_schema is present, content is already parsed
      result = response.message.content

        # Verify the structure matches our schema
        assert result.key?("description")
        assert result.key?("objects")
        assert result.key?("scene_type")
        assert result.key?("primary_colors")
        assert result["objects"].is_a?(Array)
        assert [ "indoor", "outdoor", "abstract", "document", "photo", "illustration" ].include?(result["scene_type"])
      end
    end
  end

  test "analyzes remote image URL without structured output" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_remote_image_basic") do
      # Use a landscape image URL for basic analysis
      image_url = "https://picsum.photos/400/300"

      # For now, just use analyze_image without the structured output schema
      # We'll get a natural language description instead of JSON
      prompt = OpenRouterIntegrationAgent.with(image_url: image_url).analyze_image
      response = prompt.generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert response.message.content.is_a?(String)
      assert response.message.content.length > 10
      # Since analyze_image uses structured output, we'll get JSON
      # Just verify we got a response
      # In the future, we could add a simple_analyze action without schema

      # Generate documentation example
      doc_example_output(response)
    end
  end

  test "extracts receipt data with structured output from local file" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_receipt_extraction_local") do
      # Use the test receipt image - file exists, no conditional needed
      receipt_path = Rails.root.join("..", "..", "test", "fixtures", "images", "test_receipt.png")

      prompt = OpenRouterIntegrationAgent.with(image_path: receipt_path).extract_receipt_data
      response = prompt.generate_now

      assert_not_nil response
      assert_not_nil response.message

      # When output_schema is present, content is already parsed
      result = response.message.content

      assert_equal result["merchant"]["name"], "Corner Mart"
      assert_equal result["total"]["amount"], 14.83
      assert_equal result["items"].size, 4
      result["items"].each do |item|
        assert item.key?("name")
        assert item.key?("quantity")
        assert item.key?("price")
      end
      assert_equal result["items"][0], { "name"=>"Milk", "quantity"=>1, "price"=>3.49 }
      assert_equal result["items"][1], { "name"=>"Bread", "quantity"=>1, "price"=>2.29 }
      assert_equal result["items"][2], { "name"=>"Apples", "quantity"=>1, "price"=>5.1 }
      assert_equal result["items"][3], { "name"=>"Eggs", "quantity"=>1, "price"=>2.99 }
      # Generate documentation example
      doc_example_output(response)
    end
  end

  test "handles base64 encoded images with sales chart" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_base64_sales_chart") do
      # Use the sales chart image
      chart_path = Rails.root.join("..", "..", "test", "fixtures", "images", "sales_chart.png")

      prompt = OpenRouterIntegrationAgent.with(image_path: chart_path).analyze_image
      response = prompt.generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert_includes response.message.content, "(Q1, Q2, Q3, Q4), with varying heights indicating different sales amounts"

      # Generate documentation example
      doc_example_output(response)
    end
  end

  test "processes PDF document from local file" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_pdf_local") do
      # Use the sample resume PDF
      pdf_path = Rails.root.join("..", "..", "test", "fixtures", "files", "sample_resume.pdf")

      # Read and encode the PDF as base64 - OpenRouter accepts PDFs as image_url with data URL
      pdf_data = Base64.strict_encode64(File.read(pdf_path))

      prompt = OpenRouterIntegrationAgent.with(
        pdf_data: pdf_data,
        prompt_text: "Extract information from this document and return as JSON",
        output_schema: :resume_schema
      ).analyze_pdf
      response = prompt.generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert response.message.content.present?

      # When output_schema is present, content is already parsed
      result = response.message.content

      assert_equal result["name"], "John Doe"
      assert_equal result["email"], "john.doe@example.com"
      assert_equal result["phone"], "(555) 123-4567"
      assert_equal result["education"].first, { "degree"=>"BS Computer Science", "institution"=>"Stanford University", "year"=>2020 }
      assert_equal result["experience"].first, { "job_title"=>"Senior Software Engineer", "company"=>"TechCorp", "duration"=>"2020-2024" }

      # Generate documentation example
      doc_example_output(response)
    end
  end
  # endregion pdf_processing_local

  test "processes PDF from remote URL of resume no plugins" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_pdf_remote_no_plugin") do
      pdf_url = "https://docs.activeagents.ai/sample_resume.pdf"

      prompt = OpenRouterIntegrationAgent.with(
        pdf_url: pdf_url,
        prompt_text: "Analyze the PDF",
        output_schema: :resume_schema,
        skip_plugin: true
      ).analyze_pdf

      # Remote URLs are not supported without a PDF engine plugin
      # OpenAI: Inputs by file URL are not supported for chat completions. Use the ResponsesAPI for this option.
      # https://platform.openai.com/docs/guides/pdf-files#file-urls
      # Accept either the OpenAI error directly or our wrapped error
      # Suppress ruby-openai gem's error output to STDERR
      error = assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError, OpenAI::Error) do
        prompt.generate_now
      end

      # Check the error message regardless of which error type was raised
      error_message = error.message
      assert_match(/Missing required parameter.*file_id/, error_message)
      assert_match(/Provider returned error|invalid_request_error/, error_message)
    end
  end

  # region pdf_native_support
  test "processes PDF with native model support" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_pdf_native") do
      # Test with a model that might have native PDF support
      # Using the native engine (charged as input tokens)
      pdf_path = Rails.root.join("..", "..", "test", "fixtures", "files", "sample_resume.pdf")
      pdf_data = Base64.strict_encode64(File.read(pdf_path))

      prompt = OpenRouterIntegrationAgent.with(
        pdf_data: pdf_data,
        prompt_text: "Analyze this PDF document",
        pdf_engine: "native"  # Use native engine (charged as input tokens)
      ).analyze_pdf

      # First verify the prompt has the plugins in options
      assert prompt.options[:plugins].present?, "Plugins should be present in prompt options"
      assert prompt.options[:fallback_models].present?, "Fallback models should be present in prompt options"
      assert_equal "file-parser", prompt.options[:plugins][0][:id]
      assert_equal "native", prompt.options[:plugins][0][:pdf][:engine]

      response = prompt.generate_now

      assert_not_nil response
      assert_not_nil response.message
      assert response.message.content.present?
      assert_includes response.message.content, "John Doe"

      # Generate documentation example
      doc_example_output(response)
    end
  end
  # endregion pdf_native_support

  test "processes PDF without any plugin for models with built-in support" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_pdf_no_plugin") do
      # Test without any plugin - for models that have built-in PDF support
      pdf_url = "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"

      prompt = OpenRouterIntegrationAgent.with(
        pdf_url: pdf_url,
        prompt_text: "Analyze this PDF document",
        skip_plugin: true  # Don't use any plugin
      ).analyze_pdf

      # Verify no plugins are included when skip_plugin is true
      assert_empty prompt.options[:plugins], "Should not have plugins when skip_plugin is true"

      response = prompt.generate_now
      raw_response = response.raw_response
      assert_equal "Google", raw_response["provider"]
      assert_not_nil response
      assert_not_nil response.message
      assert response.message.content.present?
      # Generate documentation example
      doc_example_output(response)
    end
  end

  test "processes scanned PDF with OCR engine" do
    skip "Requires actual OpenRouter API key and credits" unless has_openrouter_credentials?

    VCR.use_cassette("openrouter_pdf_ocr") do
      # Test with the mistral-ocr engine for scanned documents
      # Using a simple PDF that should be processable
      pdf_url = "https://docs.activeagents.ai/sample_resume.pdf"

      prompt = OpenRouterIntegrationAgent.with(
        pdf_url: pdf_url,
        prompt_text: "Extract text from this PDF.",
        output_schema: :resume_schema,
        pdf_engine: "mistral-ocr"  # OCR engine for text extraction
      ).analyze_pdf

      # Verify OCR engine is specified
      assert prompt.options[:plugins].present?, "Should have plugins for OCR"
      assert_equal "mistral-ocr", prompt.options[:plugins][0][:pdf][:engine]

      response = prompt.generate_now

      # MUST return valid JSON - no fallback allowed
      raw_response = response.raw_response
      # When output_schema is present, content is already parsed
      result = response.message.content

      assert_equal result["name"], "John Doe"
      assert_equal result["email"], "john.doe@example.com"
      assert_equal result["phone"], "(555) 123-4567"
      assert_equal result["education"], [ { "degree"=>"BS Computer Science", "institution"=>"Stanford University", "year"=>2020 } ]
      assert_equal result["experience"], [ { "job_title"=>"Senior Software Engineer", "company"=>"TechCorp", "duration"=>"2020-2024" } ]

      # Generate documentation example
      doc_example_output(response)
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
        possible_models = [ "openai/gpt-3.5-turbo-0301", "openai/gpt-3.5-turbo", "openai/gpt-4o-mini" ]
        assert possible_models.include?(response.metadata[:model_used])
        assert response.metadata[:provider].present?
      end

      # The response should still work (2+2=4)
      assert response.message.content.include?("4")

      # Generate documentation example
      doc_example_output(response)
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

      # Generate documentation example
      doc_example_output(response)
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

      # Generate documentation example
      doc_example_output(response)
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
        "order" => [ "OpenAI", "Anthropic" ],
        "require_parameters" => true,
        "data_collection" => "deny"
      }
    )

    prefs = provider.send(:build_provider_preferences)

    assert_equal [ "OpenAI", "Anthropic" ], prefs[:order]
    assert_equal true, prefs[:require_parameters]
    assert_equal true, prefs[:allow_fallbacks]
    assert_equal "deny", prefs[:data_collection]
  end

  test "configures data collection policies" do
    # Test deny all data collection
    provider_deny = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o",
      "data_collection" => "deny"
    )
    prefs_deny = provider_deny.send(:build_provider_preferences)
    assert_equal "deny", prefs_deny[:data_collection]

    # Test allow all data collection (default)
    provider_allow = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o"
    )
    prefs_allow = provider_allow.send(:build_provider_preferences)
    assert_equal "allow", prefs_allow[:data_collection]

    # Test selective provider data collection
    provider_selective = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o",
      "data_collection" => [ "OpenAI", "Google" ]
    )
    prefs_selective = provider_selective.send(:build_provider_preferences)
    assert_equal [ "OpenAI", "Google" ], prefs_selective[:data_collection]
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
      messages: [ message ]
    )

    assert prompt.multimodal?
  end

  test "converts file type to image_url for OpenRouter PDF support" do
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o"
    )

    # Test file type conversion
    file_item = {
      type: "file",
      file: {
        file_data: "data:application/pdf;base64,JVBERi0xLj..."
      }
    }

    formatted = provider.send(:format_content_item, file_item)

    assert_equal "image_url", formatted[:type]
    assert_equal "data:application/pdf;base64,JVBERi0xLj...", formatted[:image_url][:url]
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

  test "includes plugins parameter when passed in options" do
    provider = ActiveAgent::GenerationProvider::OpenRouterProvider.new(
      "model" => "openai/gpt-4o"
    )

    # Create a prompt with plugins option
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      message: "test",
      options: {
        plugins: [
          {
            id: "file-parser",
            pdf: {
              engine: "pdf-text"
            }
          }
        ]
      }
    )

    # Set the prompt on the provider
    provider.instance_variable_set(:@prompt, prompt)

    # Build parameters and verify plugins are included
    parameters = provider.send(:build_openrouter_parameters)

    assert_not_nil parameters[:plugins]
    assert_equal 1, parameters[:plugins].size
    assert_equal "file-parser", parameters[:plugins][0][:id]
    assert_equal "pdf-text", parameters[:plugins][0][:pdf][:engine]
  end
end
