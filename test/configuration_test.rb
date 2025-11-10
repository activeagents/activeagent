# frozen_string_literal: true

require "test_helper"
require "tempfile"

class ConfigurationTest < ActiveSupport::TestCase
  setup do
    @original_config = ActiveAgent.configuration
    ActiveAgent.reset_configuration!
  end

  teardown do
    ActiveAgent.instance_variable_set(:@configuration, @original_config)
  end

  # Test default configuration values
  test "initializes with default values" do
    config = ActiveAgent::Configuration.new

    # Configuration now primarily stores provider settings
    assert_not_nil config
  end

  # Test custom initialization
  test "initializes with custom settings" do
    config = ActiveAgent::Configuration.new(
      openai: { service: "OpenAI", model: "gpt-4o" }
    )

    assert_equal "OpenAI", config[:openai]["service"]
  end

  # Test hash-like access
  test "supports hash-like access with []" do
    config = ActiveAgent::Configuration.new(
      openai: { model: "gpt-4o" }
    )

    assert_equal "gpt-4o", config[:openai]["model"]
    assert_equal "gpt-4o", config["openai"]["model"]
  end

  test "supports hash-like assignment with []=" do
    config = ActiveAgent::Configuration.new

    config[:openai] = { model: "gpt-4o" }
    assert_equal "gpt-4o", config[:openai]["model"]
  end

  # Test method_missing delegation
  test "accesses configuration via method syntax" do
    config = ActiveAgent::Configuration.new(
      openai: { model: "gpt-4o" }
    )

    assert_equal "gpt-4o", config.openai["model"]
  end

  test "returns nil for undefined configuration keys" do
    config = ActiveAgent::Configuration.new

    assert_nil config.nonexistent_key
    assert_nil config[:nonexistent_key]
  end

  test "respond_to_missing? works correctly" do
    config = ActiveAgent::Configuration.new

    assert config.respond_to?(:logger)
    refute config.respond_to?(:nonexistent_key)
  end

  # Test provider configuration storage
  test "stores provider-specific configuration" do
    config = ActiveAgent::Configuration.new(
      openai: { service: "OpenAI", model: "gpt-4o" },
      anthropic: { service: "Anthropic", model: "claude-3-5-sonnet-20241022" }
    )

    assert_equal "OpenAI", config[:openai][:service]
    assert_equal "gpt-4o", config[:openai][:model]
    assert_equal "Anthropic", config[:anthropic][:service]
  end

  test "converts hashes to indifferent access" do
    config = ActiveAgent::Configuration.new(
      openai: { "service" => "OpenAI", "model" => "gpt-4o" }
    )

    # Should be accessible with both string and symbol keys
    assert_equal "OpenAI", config[:openai][:service]
    assert_equal "OpenAI", config[:openai]["service"]
    assert_equal "gpt-4o", config[:openai][:model]
    assert_equal "gpt-4o", config[:openai]["model"]
  end

  test "converts nested hashes to indifferent access" do
    config = ActiveAgent::Configuration.new(
      openai: {
        "service" => "OpenAI",
        "parameters" => {
          "temperature" => 0.7,
          "max_tokens" => 1000
        }
      }
    )

    assert_equal 0.7, config[:openai][:parameters][:temperature]
    assert_equal 0.7, config[:openai]["parameters"]["temperature"]
  end

  # Test YAML file loading
  test "loads provider configuration from YAML file" do
    yaml_content = <<~YAML
      development:
        openai:
          service: "OpenAI"
          model: "gpt-4o-mini"
          temperature: 0.7
        anthropic:
          service: "Anthropic"
          model: "claude-3-5-sonnet-20241022"
    YAML

    Tempfile.create([ "config", ".yml" ]) do |file|
      file.write(yaml_content)
      file.rewind

      ENV["RAILS_ENV"] = "development"
      config = ActiveAgent::Configuration.load(file.path)

      assert_equal "OpenAI", config[:openai][:service]
      assert_equal "gpt-4o-mini", config[:openai][:model]
      assert_equal 0.7, config[:openai][:temperature]
      assert_equal "Anthropic", config[:anthropic][:service]
    ensure
      ENV.delete("RAILS_ENV")
    end
  end

  test "supports ERB in YAML file" do
    yaml_content = <<~YAML
      development:
        openai:
          service: "OpenAI"
          access_token: <%= "test_token_123" %>
    YAML

    Tempfile.create([ "config", ".yml" ]) do |file|
      file.write(yaml_content)
      file.rewind

      ENV["RAILS_ENV"] = "development"
      config = ActiveAgent::Configuration.load(file.path)

      assert_equal "test_token_123", config[:openai][:access_token]
    ensure
      ENV.delete("RAILS_ENV")
    end
  end

  test "falls back to root config if environment not found" do
    yaml_content = <<~YAML
      openai:
        service: "OpenAI"
        model: "gpt-4o"
    YAML

    Tempfile.create([ "config", ".yml" ]) do |file|
      file.write(yaml_content)
      file.rewind

      ENV["RAILS_ENV"] = "nonexistent_env"
      config = ActiveAgent::Configuration.load(file.path)

      assert_equal "OpenAI", config[:openai][:service]
      assert_equal "gpt-4o", config[:openai][:model]
    ensure
      ENV.delete("RAILS_ENV")
    end
  end

  test "returns empty config when file does not exist" do
    config = ActiveAgent::Configuration.load("/path/to/nonexistent/file.yml")

    # Should still be a valid configuration object
    assert_not_nil config
  end

  # Test global configuration methods
  test "ActiveAgent.configuration returns global instance" do
    config1 = ActiveAgent.configuration
    config2 = ActiveAgent.configuration

    assert_same config1, config2
  end

  test "ActiveAgent.configure yields configuration" do
    ActiveAgent.configure do |config|
      config[:openai] = { service: "OpenAI", model: "gpt-4o" }
    end

    assert_equal "OpenAI", ActiveAgent.configuration[:openai]["service"]
    assert_equal "gpt-4o", ActiveAgent.configuration[:openai]["model"]
  end

  test "ActiveAgent.configure returns configuration" do
    result = ActiveAgent.configure do |config|
      config[:anthropic] = { service: "Anthropic" }
    end

    assert_instance_of ActiveAgent::Configuration, result
    assert_equal "Anthropic", result[:anthropic]["service"]
  end

  test "ActiveAgent.reset_configuration! creates new instance" do
    ActiveAgent.configuration[:test_key] = "test_value"
    original = ActiveAgent.configuration

    ActiveAgent.reset_configuration!
    new_config = ActiveAgent.configuration

    refute_same original, new_config
    assert_nil new_config[:test_key]
  end

  test "ActiveAgent::Base.logger can be manually set in configure block" do
    custom_logger = Logger.new(STDERR)

    ActiveAgent.configure do |config|
      ActiveAgent::Base.logger = custom_logger
    end

    assert_equal custom_logger, ActiveAgent::Base.logger

    # Reset to Rails logger
    ActiveAgent::Base.logger = Rails.logger
  end

  test "config.logger proxy accessor works" do
    custom_logger = Logger.new(STDERR)

    ActiveAgent.configure do |config|
      config.logger = custom_logger
    end

    assert_equal custom_logger, ActiveAgent.configuration.logger
    assert_equal custom_logger, ActiveAgent::Base.logger

    # Reset to Rails logger
    ActiveAgent.configure do |config|
      config.logger = Rails.logger
    end
  end

  test "ActiveAgent.configuration_load sets global configuration" do
    yaml_content = <<~YAML
      development:
        openai:
          service: "OpenAI"
          model: "gpt-4o"
          max_retries: 5
    YAML

    Tempfile.create([ "config", ".yml" ]) do |file|
      file.write(yaml_content)
      file.rewind

      ENV["RAILS_ENV"] = "development"
      ActiveAgent.configuration_load(file.path)

      assert_equal "OpenAI", ActiveAgent.configuration[:openai][:service]
      assert_equal 5, ActiveAgent.configuration[:openai][:max_retries]
    ensure
      ENV.delete("RAILS_ENV")
    end
  end

  # Test array conversion to indifferent access
  test "converts arrays with hashes to indifferent access" do
    config = ActiveAgent::Configuration.new(
      providers: [
        { "name" => "openai", "model" => "gpt-4o" },
        { "name" => "anthropic", "model" => "claude-3-5-sonnet-20241022" }
      ]
    )

    assert_equal "openai", config[:providers][0][:name]
    assert_equal "openai", config[:providers][0]["name"]
  end

  # Test DEFAULTS constant
  test "DEFAULTS constant is frozen" do
    assert ActiveAgent::Configuration::DEFAULTS.frozen?
  end
end
