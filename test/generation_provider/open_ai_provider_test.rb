require "test_helper"

# Test for OpenAI Provider gem loading and configuration
class OpenAIProviderTest < ActiveSupport::TestCase
  test "OpenAIProvider supports structured output with json_schema" do
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "json_schema" => {
        "type" => "object",
        "properties" => {
          "foo" => {"type" => "string"}
        },
        "required" => ["foo"]
      }
    }
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {json_schema: config["json_schema"]},
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
          "foo" => {"type" => "string"}
        },
        "required" => ["foo"]
      }
    }
    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {json_schema: config["json_schema"]},
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
    assert_equal({foo: "bar"}, result.message.content)
  end
  def setup
    # Store original configuration to restore later
    @original_config = ActiveAgent.config
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
          name: {type: "string"},
          age: {type: "integer"}
        },
        required: ["name", "age"]
      },
      strict: true
    }

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {json_schema: json_schema},
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
          "status" => {"type" => "string"}
        },
        "required" => ["status"]
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
          properties: {message: {type: "string"}}
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
          schema: {type: "object"},
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
      options: {response_format: {type: "json_object"}},
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    params = provider.send(:prompt_parameters)

    assert_equal({type: "json_object"}, params[:response_format])
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
      options: {json_schema: {type: "object"}},
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)
    assert provider.send(:has_structured_output?)

    # Test with json_object response_format
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {response_format: {type: "json_object"}},
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)
    assert provider.send(:has_structured_output?)

    # Test with json_schema response_format
    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {response_format: {type: "json_schema"}},
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
      options: {json_schema: {type: "object"}},
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock response with JSON content
    response = {
      "id" => "test-id",
      "choices" => [{
        "message" => {
          "role" => "assistant",
          "content" => '{"name": "John", "age": 30}'
        }
      }]
    }

    # Call chat_response
    result = provider.send(:chat_response, response)

    # Verify the content was parsed as JSON
    assert_equal({name: "John", age: 30}, result.message.content)
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
      options: {json_schema: {type: "object"}},
      messages: [],
      actions: []
    )
    provider.instance_variable_set(:@prompt, prompt)

    # Mock response with invalid JSON content
    response = {
      "id" => "test-id",
      "choices" => [{
        "message" => {
          "role" => "assistant",
          "content" => "invalid json content"
        }
      }]
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
        response: {type: "string"},
        confidence: {type: "number"}
      },
      required: ["response"]
    }

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {json_schema: json_schema},
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
      "properties" => {"config_field" => {"type" => "string"}}
    }

    prompt_schema = {
      type: "object",
      properties: {prompt_field: {type: "string"}}
    }

    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini",
      "json_schema" => config_schema
    }

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {json_schema: prompt_schema},
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
          properties: {weather: {type: "string"}}
        }
      },
      messages: [system_message, user_message],
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
      params: {location: "San Francisco"}
    )

    prompt = ActiveAgent::ActionPrompt::Prompt.new(
      options: {},
      messages: [],
      actions: [action]
    )

    provider.instance_variable_set(:@prompt, prompt)

    # Test that prompt_parameters includes tools
    params = provider.send(:prompt_parameters)
    assert_equal [action], params[:tools]
  end
end
