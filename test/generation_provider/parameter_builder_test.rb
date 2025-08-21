# frozen_string_literal: true

require "test_helper"
require "active_agent/action_prompt/message"
require "active_agent/generation_provider/parameter_builder"
require "active_agent/generation_provider/message_formatting"
require "active_agent/generation_provider/tool_management"

class ParameterBuilderTest < ActiveSupport::TestCase
  MockPrompt = Data.define(:messages, :options, :actions, :output_schema, :message) do
    def initialize(messages: [], options: {}, actions: nil, output_schema: nil, message: nil)
      super
    end
  end

  class TestProvider
    include ActiveAgent::GenerationProvider::ParameterBuilder
    include ActiveAgent::GenerationProvider::MessageFormatting
    include ActiveAgent::GenerationProvider::ToolManagement

    attr_accessor :prompt, :config, :model_name

    def initialize(config = {})
      @config = config
    end
  end

  setup do
    @provider = TestProvider.new("temperature" => 0.5, "model" => "test-model")
    @prompt = MockPrompt.new(
      messages: [
        ActiveAgent::ActionPrompt::Message.new(role: :user, content: "Hello")
      ],
      options: {},
      actions: nil,
      output_schema: nil
    )
    @provider.prompt = @prompt
  end

  test "prompt_parameters builds complete parameters" do
    params = @provider.prompt_parameters

    assert_equal "test-model", params[:model]
    assert_equal 0.5, params[:temperature]
    assert params[:messages]
    assert_equal 1, params[:messages].length
  end

  test "prompt_parameters accepts overrides" do
    params = @provider.prompt_parameters(model: "override-model", temperature: 0.9)

    assert_equal "override-model", params[:model]
    assert_equal 0.9, params[:temperature]
  end

  test "build_base_parameters includes required fields" do
    params = @provider.send(:build_base_parameters)

    assert params.key?(:model)
    assert params.key?(:messages)
    assert params.key?(:temperature)
  end

  test "build_base_parameters includes max_tokens when present" do
    @provider.config["max_tokens"] = 1000
    params = @provider.send(:build_base_parameters)

    assert_equal 1000, params[:max_tokens]
  end

  test "build_base_parameters includes tools when actions present" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options,
      actions: [
        { "name" => "tool1", "description" => "Test tool", "parameters" => {} }
      ],
      output_schema: @prompt.output_schema
    )

    params = @provider.send(:build_base_parameters)

    assert params[:tools]
    assert_equal 1, params[:tools].length
    assert_equal "function", params[:tools][0][:type]
  end

  test "build_provider_parameters returns empty hash by default" do
    params = @provider.send(:build_provider_parameters)
    assert_equal({}, params)
  end

  test "extract_prompt_options includes common options" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: {
        stream: true,
        top_p: 0.9,
        frequency_penalty: 0.1,
        presence_penalty: 0.2,
        seed: 42,
        stop: [ "\n" ],
        user: "user123"
      },
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )

    options = @provider.send(:extract_prompt_options)

    assert_equal true, options[:stream]
    assert_equal 0.9, options[:top_p]
    assert_equal 0.1, options[:frequency_penalty]
    assert_equal 0.2, options[:presence_penalty]
    assert_equal 42, options[:seed]
    assert_equal [ "\n" ], options[:stop]
    assert_equal "user123", options[:user]
  end

  test "extract_prompt_options excludes missing options" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: { stream: true },
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )

    options = @provider.send(:extract_prompt_options)

    assert_equal true, options[:stream]
    assert_not options.key?(:top_p)
    assert_not options.key?(:frequency_penalty)
  end

  test "extract_prompt_options includes response_format for output_schema" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options,
      actions: @prompt.actions,
      output_schema: {
        name: "test_schema",
        schema: { type: "object" }
      }
    )

    options = @provider.send(:extract_prompt_options)

    assert options[:response_format]
    assert_equal "json_schema", options[:response_format][:type]
    assert_equal @provider.prompt.output_schema, options[:response_format][:json_schema]
  end

  test "determine_model prioritizes prompt option over config" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(model: "prompt-model"),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.model_name = "provider-model"
    @provider.config["model"] = "config-model"

    assert_equal "prompt-model", @provider.send(:determine_model)
  end

  test "determine_model falls back to provider model_name" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(model: nil),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.model_name = "provider-model"
    @provider.config["model"] = "config-model"

    assert_equal "provider-model", @provider.send(:determine_model)
  end

  test "determine_model falls back to config model" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(model: nil),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.model_name = nil
    @provider.config["model"] = "config-model"

    assert_equal "config-model", @provider.send(:determine_model)
  end

  test "determine_temperature prioritizes prompt option" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(temperature: 0.3),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.config["temperature"] = 0.5

    assert_equal 0.3, @provider.send(:determine_temperature)
  end

  test "determine_temperature falls back to config" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(temperature: nil),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.config["temperature"] = 0.5

    assert_equal 0.5, @provider.send(:determine_temperature)
  end

  test "determine_temperature defaults to 0.7" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(temperature: nil),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.config["temperature"] = nil

    assert_equal 0.7, @provider.send(:determine_temperature)
  end

  test "determine_max_tokens from prompt options" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(max_tokens: 500),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.config["max_tokens"] = 1000

    assert_equal 500, @provider.send(:determine_max_tokens)
  end

  test "determine_max_tokens from config" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(max_tokens: nil),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.config["max_tokens"] = 1000

    assert_equal 1000, @provider.send(:determine_max_tokens)
  end

  test "build_response_format creates OpenAI format" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options,
      actions: @prompt.actions,
      output_schema: {
        name: "response",
        schema: { type: "object", properties: {} }
      }
    )

    format = @provider.send(:build_response_format)

    assert_equal "json_schema", format[:type]
    assert_equal @provider.prompt.output_schema, format[:json_schema]
  end

  test "embeddings_parameters builds embedding params" do
    @provider.config["embedding_model"] = "embed-model"
    @provider.config["embedding_dimensions"] = 768

    params = @provider.send(:embeddings_parameters,
      input: "test input",
      encoding_format: "base64"
    )

    assert_equal "embed-model", params[:model]
    assert_equal "test input", params[:input]
    assert_equal 768, params[:dimensions]
    assert_equal "base64", params[:encoding_format]
  end

  test "determine_embedding_model prioritizes prompt option" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(embedding_model: "custom-embed"),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.config["embedding_model"] = "config-embed"

    assert_equal "custom-embed", @provider.send(:determine_embedding_model)
  end

  test "determine_embedding_model defaults to text-embedding-3-small" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(embedding_model: nil),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    @provider.config["embedding_model"] = nil

    assert_equal "text-embedding-3-small", @provider.send(:determine_embedding_model)
  end

  test "format_embedding_input handles single message" do
    @provider.prompt = MockPrompt.new(
      message: ActiveAgent::ActionPrompt::Message.new(
        role: :user,
        content: "Embed this text"
      ),
      messages: nil,
      options: @prompt.options,
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )

    assert_equal "Embed this text", @provider.send(:format_embedding_input)
  end

  test "format_embedding_input handles multiple messages" do
    @provider.prompt = MockPrompt.new(
      message: nil,
      messages: [
        ActiveAgent::ActionPrompt::Message.new(role: :user, content: "First"),
        ActiveAgent::ActionPrompt::Message.new(role: :user, content: "Second")
      ],
      options: @prompt.options,
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )

    assert_equal [ "First", "Second" ], @provider.send(:format_embedding_input)
  end

  test "format_embedding_input returns nil when no input" do
    @provider.prompt = MockPrompt.new(
      message: nil,
      messages: nil,
      options: @prompt.options,
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )

    assert_nil @provider.send(:format_embedding_input)
  end

  test "parameter precedence order" do
    # Setup all parameter sources
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: {
        model: "prompt-model",
        temperature: 0.1,
        max_tokens: 100
      },
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )

    @provider.config = {
      "model" => "config-model",
      "temperature" => 0.5,
      "max_tokens" => 500
    }

    # Provider-specific params
    class CustomProvider < TestProvider
      protected
      def build_provider_parameters
        { custom_param: "provider_value", temperature: 0.3 }
      end
    end

    provider = CustomProvider.new(@provider.config)
    provider.prompt = @provider.prompt

    # Test with overrides
    params = provider.prompt_parameters(temperature: 0.9, another_param: "override")

    # Verify precedence: overrides > prompt options > provider params > base params
    assert_equal "prompt-model", params[:model] # From prompt options
    assert_equal 0.9, params[:temperature] # From overrides
    assert_equal 100, params[:max_tokens] # From prompt options
    assert_equal "provider_value", params[:custom_param] # From provider params
    assert_equal "override", params[:another_param] # From overrides
  end

  test "compact removes nil values" do
    @provider.prompt = MockPrompt.new(
      messages: @prompt.messages,
      options: @prompt.options.merge(max_tokens: nil),
      actions: @prompt.actions,
      output_schema: @prompt.output_schema
    )
    params = @provider.prompt_parameters

    assert_not params.key?(:max_tokens)
  end

  test "class method default_parameters" do
    class ConfiguredProvider < TestProvider
      default_parameters temperature: 0.8, top_p: 0.95
    end

    assert_equal({ temperature: 0.8, top_p: 0.95 }, ConfiguredProvider.get_default_parameters)
  end

  test "embeddings_parameters compact removes nil values" do
    params = @provider.send(:embeddings_parameters,
      input: "test",
      dimensions: nil
    )

    assert params.key?(:input)
    assert_not params.key?(:dimensions)
    assert_equal "float", params[:encoding_format] # Default value
  end
end
