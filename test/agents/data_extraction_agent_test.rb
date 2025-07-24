require "test_helper"

class DataExtractionAgentTest < ActiveSupport::TestCase
  setup do
    @agent = DataExtractionAgent
    # Sample base64 encoded 1x1 pixel PNG for testing
    @sample_image_base64 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    @sample_file_id = "file-123456789"
  end

  test "it renders a prompt with text content" do
    text_content = "Extract key information from this sample text."
    response_context = @agent.with(text_content: text_content).extract_from_text(text_content)
    
    assert response_context.messages.any?
    assert_equal "Extract key information from this sample text.", response_context.messages.last.content
  end

  test "it renders a prompt with multipart image content" do
    response_context = @agent.extract_from_image(@sample_image_base64)
    
    assert response_context.messages.any?
    last_message = response_context.messages.last
    assert last_message.content.is_a?(Array)
    assert_equal 2, last_message.content.length
    
    # Check text part
    text_part = last_message.content.find { |part| part["type"] == "input_text" }
    assert text_part
    assert_equal "Extract all text and information from this image", text_part["text"]
    
    # Check image part  
    image_part = last_message.content.find { |part| part["type"] == "input_image" }
    assert image_part
    assert_equal @sample_image_base64, image_part["image_url"]
  end

  test "it renders a prompt with multipart document content" do
    question = "What is the main topic of this document?"
    response_context = @agent.extract_from_document(@sample_file_id, question)
    
    assert response_context.messages.any?
    last_message = response_context.messages.last
    assert last_message.content.is_a?(Array)
    assert_equal 2, last_message.content.length
    
    # Check text part
    text_part = last_message.content.find { |part| part["type"] == "input_text" }
    assert text_part
    assert_equal question, text_part["text"]
    
    # Check file part
    file_part = last_message.content.find { |part| part["type"] == "input_file" }
    assert file_part
    assert_equal @sample_file_id, file_part["file_id"]
  end

  test "it renders a prompt with document content and default question" do
    response_context = @agent.extract_from_document(@sample_file_id)
    
    assert response_context.messages.any?
    last_message = response_context.messages.last
    assert last_message.content.is_a?(Array)
    
    # Check default text
    text_part = last_message.content.find { |part| part["type"] == "input_text" }
    assert text_part
    assert_equal "Extract all key information from this document", text_part["text"]
  end

  test "it renders a prompt with multiple input types" do
    text_part = "Analyze both the image and document content"
    response_context = @agent.extract_from_multipart(text_part, @sample_image_base64, @sample_file_id)
    
    assert response_context.messages.any?
    last_message = response_context.messages.last
    assert last_message.content.is_a?(Array)
    assert_equal 3, last_message.content.length
    
    # Check all three parts exist
    text_content = last_message.content.find { |part| part["type"] == "input_text" }
    assert text_content
    assert_equal text_part, text_content["text"]
    
    image_content = last_message.content.find { |part| part["type"] == "input_image" }
    assert image_content
    assert_equal @sample_image_base64, image_content["image_url"]
    
    file_content = last_message.content.find { |part| part["type"] == "input_file" }
    assert file_content
    assert_equal @sample_file_id, file_content["file_id"]
  end

  test "it renders a prompt with only text and image" do
    text_part = "What's in this image?"
    response_context = @agent.extract_from_multipart(text_part, @sample_image_base64)
    
    assert response_context.messages.any?
    last_message = response_context.messages.last
    assert last_message.content.is_a?(Array)
    assert_equal 2, last_message.content.length
    
    # Should have text and image, but no file
    assert last_message.content.any? { |part| part["type"] == "input_text" }
    assert last_message.content.any? { |part| part["type"] == "input_image" }
    assert_nil last_message.content.find { |part| part["type"] == "input_file" }
  end

  test "ResponsesAdapter should recognize multipart content" do
    response_context = @agent.extract_from_image(@sample_image_base64)
    # Generation object delegates to its context (the prompt)
    prompt = response_context.context
    
    # Create a provider to test the adapter selection
    config = { "api_key" => "test_key", "model" => "gpt-4o-mini" }
    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    adapter = provider.send(:select_adapter, prompt)
    
    # Should select ResponsesAdapter for multipart content
    assert_equal ActiveAgent::GenerationProvider::OpenAIAdapters::ResponsesAdapter, adapter.class
  end

  test "generates response with multipart image content using VCR" do
    VCR.use_cassette("data_extraction_agent_image_analysis") do
      response = @agent.extract_from_image(@sample_image_base64).generate_now
      
      assert response.message
      assert response.message.content.present?
      assert_equal :assistant, response.message.role
    end
  end

  test "generates response with multipart document content using VCR" do
    skip "File upload test - requires actual file upload to OpenAI"
    
    VCR.use_cassette("data_extraction_agent_document_analysis") do
      response = @agent.extract_from_document(@sample_file_id, "What are the key points?").generate_now
      
      assert response.message
      assert response.message.content.present?
      assert_equal :assistant, response.message.role
    end
  end

  test "properly handles multipart content in ResponsesAdapter" do
    response_context = @agent.extract_from_multipart("Analyze this content", @sample_image_base64)
    # Generation object delegates to its context (the prompt)
    prompt = response_context.context
    
    # Test the adapter parameters
    config = { "api_key" => "test_key", "model" => "gpt-4o-mini" }
    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    adapter = provider.send(:select_adapter, prompt)
    
    # Set the prompt on the adapter so we can test its methods
    adapter.instance_variable_set(:@prompt, prompt)
    
    # Access private method for testing
    parameters = adapter.send(:responses_parameters)
    
    assert parameters[:input]
    assert parameters[:input].is_a?(Array)
    assert parameters[:input].first["role"] == "user"
    assert parameters[:input].first["content"].is_a?(Array)
    
    # Check that the content has both text and image parts
    content_types = parameters[:input].first["content"].map { |c| c["type"] }
    assert_includes content_types, "input_text"
    assert_includes content_types, "input_image"
  end

  test "supports alternative content format with input_* types" do
    # Test the format from the user's examples
    multipart_content = [
      { "type" => "input_text", "text" => "what's in this image?" },
      { "type" => "input_image", "image_url" => @sample_image_base64 }
    ]
    
    response_context = @agent.new.prompt(message: { content: multipart_content, role: :user })
    
    assert response_context.messages.any?
    last_message = response_context.messages.last
    assert last_message.content.is_a?(Array)
    assert_equal 2, last_message.content.length
    
    # Verify the content structure
    text_part = last_message.content.find { |part| part["type"] == "input_text" }
    assert text_part
    assert_equal "what's in this image?", text_part["text"]
    
    image_part = last_message.content.find { |part| part["type"] == "input_image" }
    assert image_part
    assert_equal @sample_image_base64, image_part["image_url"]
  end

  test "supports file input format" do
    # Test the format with input_file
    multipart_content = [
      { "type" => "input_file", "filename" => "draconomicon.pdf", "file_data" => "base64encodeddata" },
      { "type" => "input_text", "text" => "What is the first dragon in the book?" }
    ]
    
    response_context = @agent.new.prompt(message: { content: multipart_content, role: :user })
    
    assert response_context.messages.any?
    last_message = response_context.messages.last
    assert last_message.content.is_a?(Array)
    assert_equal 2, last_message.content.length
    
    # Find the file part
    file_part = last_message.content.find { |part| part["type"] == "input_file" }
    assert file_part
    assert_equal "draconomicon.pdf", file_part["filename"]
    assert_equal "base64encodeddata", file_part["file_data"]
  end
end
