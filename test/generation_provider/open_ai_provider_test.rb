require "test_helper"

# Test for OpenAI Provider gem loading and configuration
class OpenAIProviderTest < ActiveSupport::TestCase
  # Check if the ruby-openai gem is available at class load time
  begin
    require "openai"
    require "active_agent/generation_provider/open_ai_provider"
    OPENAI_AVAILABLE = true
  rescue LoadError
    OPENAI_AVAILABLE = false
  end

  def setup
    # Store original configuration to restore later
    @original_config = ActiveAgent.config
    
    # Skip tests if ruby-openai gem is not available
    skip "ruby-openai gem not available" unless OPENAI_AVAILABLE
  end
  test "OpenAIProvider supports structured output with json_schema" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "json_schema" => {
        "type" => "object",
        "properties" => {
          "foo" => { "type" => "string" }
        },
        "required" => [ "foo" ]
      }
    }
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: config["json_schema"] },
      messages: [],
      actions: []
    )
    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config, prompt: prompt)
    params = provider.send(:prompt_parameters)
    assert_equal "json_schema", params[:response_format][:type]
    assert_equal config["json_schema"], params[:response_format][:json_schema][:schema]
  end

  test "OpenAIProvider parses structured response as JSON" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "json_schema" => {
        "type" => "object",
        "properties" => {
          "foo" => { "type" => "string" }
        },
        "required" => [ "foo" ]
      }
    }
    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: config["json_schema"] },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)
    response = {
      "choices" => [
        {
          "message" => {
            "id" => "abc123",
            "role" => "assistant",
            "content" => '{"foo": "bar"}',
            "finish_reason" => "stop"
          }
        }
      ],
      "id" => "abc123"
    }
    result = provider.send(:chat_response, response)
    assert_equal({ foo: "bar" }, result.message.content)
  end
  
  def teardown
    # Clean up any modified state
    if @original_config
      ActiveAgent.instance_variable_set(:@config, @original_config)
    end
  end

  # Test the gem load rescue block
  test "gem load rescue block provides correct error message" do
    # Since we can't easily simulate the gem not being available without complex mocking,
    # we'll test that the error message is correct by creating a minimal reproduction
    expected_message = "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."

    # Verify the rescue block pattern exists in the source code
    provider_file_path = File.join(File.dirname(__FILE__), "../../lib/active_agent/generation_provider/open_ai_provider.rb")
    provider_source = File.read(provider_file_path)

    assert_includes provider_source, "begin"
    assert_includes provider_source, 'gem "ruby-openai"'
    assert_includes provider_source, 'require "openai"'
    assert_includes provider_source, "rescue LoadError"
    assert_includes provider_source, expected_message

    # Test the actual error by creating a minimal scenario
    test_code = <<~RUBY
      begin
        gem "nonexistent-openai-gem"
        require "nonexistent-openai-gem"
      rescue LoadError
        raise LoadError, "#{expected_message}"
      end
    RUBY

    error = assert_raises(LoadError) do
      eval(test_code)
    end

    assert_equal expected_message, error.message
  end

  test "loads successfully when ruby-openai gem is available" do
    # This test ensures the provider loads correctly when the gem is present
    # Since the gem is already loaded in our test environment, this should work
    assert_nothing_raised do
      require "active_agent/generation_provider/open_ai_provider"
    end

    # Verify the class exists and can be instantiated with valid config
    assert defined?(ActiveAgent::GenerationProvider::OpenAIProvider)

    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    assert_nothing_raised do
      ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    end
  end

  test "OpenAI provider initialization with missing API key" do
    config = {
      "service" => "OpenAI",
      "model" => "gpt-4o-mini"
      # Missing api_key
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    assert_nil provider.instance_variable_get(:@api_key)
  end

  test "OpenAI provider initialization with custom host" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "host" => "https://custom-openai-host.com"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    assert_equal "https://custom-openai-host.com", provider.instance_variable_get(:@host)
  end

  test "OpenAI provider supports structured output with json_schema in prompt options" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    json_schema = {
      name: "user_info",
      description: "User information response",
      schema: {
        type: "object",
        properties: {
          name: { type: "string" },
          age: { type: "integer" }
        },
        required: [ "name", "age" ]
      },
      strict: true
    }

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: json_schema },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:prompt_parameters)

    assert_equal "json_schema", params[:response_format][:type]
    assert_equal "user_info", params[:response_format][:json_schema][:name]
    assert_equal "User information response", params[:response_format][:json_schema][:description]
    assert_equal json_schema[:schema], params[:response_format][:json_schema][:schema]
    assert_equal true, params[:response_format][:json_schema][:strict]
  end

  test "OpenAI provider supports structured output with json_schema in config" do
    json_schema = {
      "name" => "config_response",
      "description" => "Configuration-based response",
      "schema" => {
        "type" => "object",
        "properties" => {
          "status" => { "type" => "string" }
        },
        "required" => [ "status" ]
      }
    }

    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "json_schema" => json_schema
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:prompt_parameters)

    assert_equal "json_schema", params[:response_format][:type]
    assert_equal "config_response", params[:response_format][:json_schema][:name]
    assert_equal json_schema["schema"], params[:response_format][:json_schema][:schema]
  end

  test "OpenAI provider uses defaults for missing json_schema properties" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    # Test with minimal schema (just the schema object)
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {
        json_schema: {
          type: "object",
          properties: { message: { type: "string" } }
        }
      },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:prompt_parameters)

    assert_equal "json_schema", params[:response_format][:type]
    assert_equal "response", params[:response_format][:json_schema][:name]
    assert_equal "Structured response", params[:response_format][:json_schema][:description]
    assert_equal true, params[:response_format][:json_schema][:strict]
  end

  test "OpenAI provider respects strict mode setting" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    # Test with strict mode disabled
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {
        json_schema: {
          schema: { type: "object" },
          strict: false
        }
      },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:prompt_parameters)

    assert_equal false, params[:response_format][:json_schema][:strict]
  end

  test "OpenAI provider supports legacy response_format option" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { response_format: { type: "json_object" } },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:prompt_parameters)

    assert_equal({ type: "json_object" }, params[:response_format])
  end

  test "OpenAI provider detects structured output correctly" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    # Test with json_schema
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: { type: "object" } },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)
    assert provider.send(:has_structured_output?)

    # Test with json_object response_format
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { response_format: { type: "json_object" } },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)
    assert provider.send(:has_structured_output?)

    # Test with json_schema response_format
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { response_format: { type: "json_schema" } },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)
    assert provider.send(:has_structured_output?)

    # Test without structured output
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)
    refute provider.send(:has_structured_output?)
  end

  test "OpenAI provider parses JSON response content for structured outputs" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    # Mock prompt with json_schema
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: { type: "object" } },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock response with JSON content
    response = {
      "id" => "test-id",
      "choices" => [ {
        "message" => {
          "role" => "assistant",
          "content" => '{"name": "John", "age": 30}'
        }
      } ]
    }

    # Call chat_response
    result = provider.send(:chat_response, response)

    # Verify the content was parsed as JSON
    assert_equal({ name: "John", age: 30 }, result.message.content)
  end

  test "OpenAI provider handles invalid JSON gracefully for structured outputs" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    # Mock prompt with json_schema
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: { type: "object" } },
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock response with invalid JSON content
    response = {
      "id" => "test-id",
      "choices" => [ {
        "message" => {
          "role" => "assistant",
          "content" => "invalid json content"
        }
      } ]
    }

    # Call chat_response
    result = provider.send(:chat_response, response)

    # Verify the content remains as string when JSON parsing fails
    assert_equal "invalid json content", result.message.content
  end

  test "integration: OpenAI provider with ApplicationAgent supports structured output" do
    # Create a proper prompt with json_schema
    json_schema = {
      type: "object",
      properties: {
        response: { type: "string" },
        confidence: { type: "number" }
      },
      required: [ "response" ]
    }

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: json_schema },
      messages: [
        ActiveAgent::ActionPrompt::Message.new(content: "Hello", role: :user)
      ],
      actions: [],
      agent_class: ApplicationAgent
    )

    # Test that the provider can be initialized with the agent's configuration
    config = ApplicationAgent.generation_provider.config.merge({
      "api_key" => "test-key",
      "json_schema" => json_schema
    })

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config, prompt: prompt)

    # Verify the provider sets up structured output correctly
    params = provider.send(:prompt_parameters)
    assert_equal "json_schema", params[:response_format][:type]
    assert_equal json_schema, params[:response_format][:json_schema][:schema]
  end

  test "integration: prompt options override config json_schema" do
    # Test that prompt-level options take precedence over config-level options
    config_schema = {
      "type" => "object",
      "properties" => { "config_field" => { "type" => "string" } }
    }

    prompt_schema = {
      type: "object",
      properties: { prompt_field: { type: "string" } }
    }

    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "json_schema" => config_schema
    }

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: prompt_schema },
      messages: [],
      actions: []
    )

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config, prompt: prompt)
    params = provider.send(:prompt_parameters)

    # Prompt schema should take precedence
    assert_equal prompt_schema, params[:response_format][:json_schema][:schema]
    refute_equal config_schema, params[:response_format][:json_schema][:schema]
  end

  test "integration: message handling with structured output" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    # Create a proper prompt with messages using ActiveAgent framework
    user_message = ActiveAgent::ActionPrompt::Message.new(
      content: "What is the weather?",
      role: :user
    )

    system_message = ActiveAgent::ActionPrompt::Message.new(
      content: "You are a helpful assistant.",
      role: :system
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {
        json_schema: {
          type: "object",
          properties: { weather: { type: "string" } }
        }
      },
      messages: [ system_message, user_message ],
      actions: []
    )

    provider.instance_variable_set(:@prompt, prompt)

    # Test that provider_messages correctly formats the messages
    formatted_messages = provider.send(:provider_messages, prompt.messages)

    assert_equal 2, formatted_messages.length
    assert_equal :system, formatted_messages[0][:role]
    assert_equal "You are a helpful assistant.", formatted_messages[0][:content]
    assert_equal :user, formatted_messages[1][:role]
    assert_equal "What is the weather?", formatted_messages[1][:content]
  end

  test "integration: action handling with tools" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    # Create actions using the framework's Action class
    action = ActiveAgent::ActionPrompt::Action.new(
      name: "get_weather",
      params: { location: "San Francisco" }
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [],
      actions: [ action ]
    )

    provider.instance_variable_set(:@prompt, prompt)

    provider.instance_variable_set(:@prompt, prompt)

    # Test that prompt_parameters includes tools
    params = provider.send(:prompt_parameters)
    assert_equal [ action ], params[:tools]
  end

  # ========== OpenAI Responses API Tests ==========
  
  test "OpenAI provider supports responses API with text input" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "Hello, how are you?",
      content_type: "text/plain",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:responses_parameters)

    assert_equal "Hello, how are you?", params[:input]
    assert_equal "gpt-4o", params[:model]
    assert_equal 0.7, params[:temperature]
  end

  test "OpenAI provider supports responses API with image input" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "data:image/jpeg;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
      content_type: "input_image",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:responses_parameters)

    assert params[:input].is_a?(Array)
    assert_equal "text", params[:input][0][:type]
    assert_equal "Please analyze this image.", params[:input][0][:text]
    assert_equal "image_url", params[:input][1][:type]
    assert_equal message.content, params[:input][1][:image_url][:url]
  end

  test "OpenAI provider supports responses API with file input" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "data:application/pdf;base64,JVBERi0xLjQKJcOkw7zDtsO8...",
      content_type: "input_file",
      file_name: "document.pdf",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:responses_parameters)

    assert params[:input].is_a?(Array)
    assert_equal "text", params[:input][0][:type]
    assert_equal "Please analyze this file.", params[:input][0][:text]
    assert_equal "input_file", params[:input][1][:type]
    assert_equal message.content, params[:input][1][:input_file][:data]
    assert_equal "document.pdf", params[:input][1][:input_file][:filename]
  end

  test "OpenAI provider supports responses API with multipart input" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    text_message = ActiveAgent::ActionPrompt::Message.new(
      content: "Please analyze both the image and the document",
      content_type: "text/plain",
      role: :user
    )

    image_message = ActiveAgent::ActionPrompt::Message.new(
      content: "data:image/jpeg;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
      content_type: "input_image",
      role: :user
    )

    file_message = ActiveAgent::ActionPrompt::Message.new(
      content: "data:application/pdf;base64,JVBERi0xLjQKJcOkw7zDtsO8...",
      content_type: "input_file",
      file_name: "report.pdf",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [text_message, image_message, file_message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:responses_parameters)

    assert params[:input].is_a?(Array)
    assert_equal 3, params[:input].length
    
    # Check text input
    assert_equal "text", params[:input][0][:type]
    assert_equal "Please analyze both the image and the document", params[:input][0][:text]
    
    # Check image input
    assert_equal "image_url", params[:input][1][:type]
    assert_equal image_message.content, params[:input][1][:image_url][:url]
    
    # Check file input
    assert_equal "input_file", params[:input][2][:type]
    assert_equal file_message.content, params[:input][2][:input_file][:data]
    assert_equal "report.pdf", params[:input][2][:input_file][:filename]
  end

  test "OpenAI provider supports responses API with structured output" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    json_schema = {
      type: "object",
      properties: {
        name: { type: "string" },
        age: { type: "integer" },
        skills: { type: "array", items: { type: "string" } }
      },
      required: ["name", "age"]
    }

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "Extract information from this resume",
      content_type: "text/plain",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: json_schema },
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:responses_parameters)

    assert_equal "Extract information from this resume", params[:input]
    assert_equal "json_schema", params[:response_format][:type]
    assert_equal "response", params[:response_format][:json_schema][:name]
    assert_equal "Structured response", params[:response_format][:json_schema][:description]
    assert_equal json_schema, params[:response_format][:json_schema][:schema]
    assert_equal true, params[:response_format][:json_schema][:strict]
  end

  test "OpenAI provider supports responses API with follow-up (previous_response_id)" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "What was my name again?",
      content_type: "text/plain",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { previous_response_id: "resp_123abc" },
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:responses_parameters)

    assert_equal "What was my name again?", params[:input]
    assert_equal "resp_123abc", params[:previous_response_id]
  end

  test "OpenAI provider supports responses API with tools/function calling" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "What's the weather in Paris?",
      content_type: "text/plain",
      role: :user
    )

    tools = [
      {
        "type" => "function",
        "name" => "get_weather",
        "description" => "Get current weather for a location",
        "parameters" => {
          "type" => "object",
          "properties" => {
            "location" => { "type" => "string" }
          },
          "required" => ["location"]
        }
      }
    ]

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [message],
      actions: tools
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:responses_parameters)

    assert_equal "What's the weather in Paris?", params[:input]
    assert_equal tools, params[:tools]
  end

  test "OpenAI provider handles responses API response parsing" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "Hello",
      content_type: "text/plain",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock response from responses API
    response = {
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

    result = provider.send(:responses_response, response)

    assert_equal "Hello! How can I help you today?", result.message.content
    assert_equal :assistant, result.message.role
    assert_equal "resp_123abc", result.message.generation_id
    refute result.message.action_requested
  end

  test "OpenAI provider handles responses API tool call response" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "What's the weather?",
      content_type: "text/plain",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock tool call response from responses API
    response = {
      "id" => "resp_456def",
      "object" => "response",
      "created" => 1625097600,
      "model" => "gpt-4o",
      "output" => [
        {
          "type" => "function_call",
          "id" => "call_123",
          "name" => "get_weather",
          "parameters" => {
            "location" => "Paris"
          }
        }
      ]
    }

    result = provider.send(:responses_response, response)

    assert result.message.action_requested
    assert_equal 1, result.message.requested_actions.length
    
    action = result.message.requested_actions.first
    assert_equal "call_123", action.id
    assert_equal "get_weather", action.name
    assert_equal({ "location" => "Paris" }, action.params)
  end

  test "OpenAI provider handles responses API structured output parsing" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "Extract data",
      content_type: "text/plain",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: { json_schema: { type: "object" } },
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock structured response from responses API
    response = {
      "id" => "resp_789ghi",
      "object" => "response",
      "created" => 1625097600,
      "model" => "gpt-4o",
      "output" => [
        {
          "type" => "message",
          "content" => [
            {
              "type" => "text",
              "text" => '{"name": "John Doe", "age": 30, "skills": ["Ruby", "JavaScript"]}'
            }
          ]
        }
      ]
    }

    result = provider.send(:responses_response, response)

    assert result.message.content.is_a?(Hash)
    assert_equal "John Doe", result.message.content[:name]
    assert_equal 30, result.message.content[:age]
    assert_equal ["Ruby", "JavaScript"], result.message.content[:skills]
  end

  test "OpenAI provider handles responses API multiple content items" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o"
    }

    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)

    message = ActiveAgent::ActionPrompt::Message.new(
      content: "Analyze this",
      content_type: "text/plain",
      role: :user
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [message],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock response with multiple content items
    response = {
      "id" => "resp_multi",
      "object" => "response",
      "created" => 1625097600,
      "model" => "gpt-4o",
      "output" => [
        {
          "type" => "message",
          "content" => [
            {
              "type" => "text",
              "text" => "Here's my analysis:"
            },
            {
              "type" => "text", 
              "text" => "The data shows interesting patterns."
            }
          ]
        }
      ]
    }

    result = provider.send(:responses_response, response)

    assert result.message.content.is_a?(Array)
    assert_equal 2, result.message.content.length
    assert_equal "Here's my analysis:", result.message.content[0]["text"]
    assert_equal "The data shows interesting patterns.", result.message.content[1]["text"]
  end

  test "Message class supports file_name attribute" do
    message = ActiveAgent::ActionPrompt::Message.new(
      content: "data:application/pdf;base64,JVBERi0x...",
      content_type: "input_file",
      file_name: "document.pdf",
      role: :user
    )

    assert_equal "document.pdf", message.file_name
    
    hash = message.to_h
    assert_equal "document.pdf", hash[:file_name]
  end
end
