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

    assert_equal false, config.verbose_generation_errors
    assert_equal true, config.retries
    assert_equal 3, config.retries_count
    assert_includes config.retries_on, EOFError
    assert_includes config.retries_on, Timeout::Error
  end

  test "verbose_generation_errors? returns boolean" do
    config = ActiveAgent::Configuration.new
    assert_equal false, config.verbose_generation_errors?

    config.verbose_generation_errors = true
    assert_equal true, config.verbose_generation_errors?
  end

  # Test custom initialization
  test "initializes with custom settings" do
    config = ActiveAgent::Configuration.new(
      verbose_generation_errors: true,
      retries_count: 5
    )

    assert_equal true, config.verbose_generation_errors
    assert_equal 5, config.retries_count
  end

  # Test hash-like access
  test "supports hash-like access with []" do
    config = ActiveAgent::Configuration.new(retries_count: 10)

    assert_equal 10, config[:retries_count]
    assert_equal 10, config["retries_count"]
  end

  test "supports hash-like assignment with []=" do
    config = ActiveAgent::Configuration.new

    config[:retries_count] = 7
    assert_equal 7, config.retries_count

    config["verbose_generation_errors"] = true
    assert_equal true, config.verbose_generation_errors
  end

  # Test method_missing delegation
  test "accesses configuration via method syntax" do
    config = ActiveAgent::Configuration.new(retries_count: 15)

    assert_equal 15, config.retries_count
    assert_equal true, config.retries
  end

  test "returns nil for undefined configuration keys" do
    config = ActiveAgent::Configuration.new

    assert_nil config.nonexistent_key
    assert_nil config[:nonexistent_key]
  end

  test "respond_to_missing? works correctly" do
    config = ActiveAgent::Configuration.new

    assert config.respond_to?(:retries)
    assert config.respond_to?(:retries_count)
    refute config.respond_to?(:nonexistent_key)
  end

  # Test retries setter validation
  test "retries accepts false" do
    config = ActiveAgent::Configuration.new
    config.retries = false
    assert_equal false, config.retries
  end

  test "retries accepts true" do
    config = ActiveAgent::Configuration.new
    config.retries = true
    assert_equal true, config.retries
  end

  test "retries accepts callable object" do
    retry_proc = ->(block) { block.call }
    config = ActiveAgent::Configuration.new
    config.retries = retry_proc

    assert_equal retry_proc, config.retries
  end

  test "retries raises error for invalid value" do
    config = ActiveAgent::Configuration.new

    error = assert_raises(ArgumentError) do
      config.retries = "invalid"
    end

    assert_includes error.message, "retries must be false, true, or a callable object"
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
  test "loads configuration from YAML file" do
    yaml_content = <<~YAML
      development:
        retries: false
        retries_count: 10
        verbose_generation_errors: true
    YAML

    Tempfile.create([ "config", ".yml" ]) do |file|
      file.write(yaml_content)
      file.rewind

      ENV["RAILS_ENV"] = "development"
      config = ActiveAgent::Configuration.load(file.path)

      assert_equal false, config.retries
      assert_equal 10, config.retries_count
      assert_equal true, config.verbose_generation_errors
    ensure
      ENV.delete("RAILS_ENV")
    end
  end

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
      retries: false
      retries_count: 20
    YAML

    Tempfile.create([ "config", ".yml" ]) do |file|
      file.write(yaml_content)
      file.rewind

      ENV["RAILS_ENV"] = "nonexistent_env"
      config = ActiveAgent::Configuration.load(file.path)

      assert_equal false, config.retries
      assert_equal 20, config.retries_count
    ensure
      ENV.delete("RAILS_ENV")
    end
  end

  test "returns empty config when file does not exist" do
    config = ActiveAgent::Configuration.load("/path/to/nonexistent/file.yml")

    # Should still have default values
    assert_equal true, config.retries
    assert_equal 3, config.retries_count
  end

  # Test global configuration methods
  test "ActiveAgent.configuration returns global instance" do
    config1 = ActiveAgent.configuration
    config2 = ActiveAgent.configuration

    assert_same config1, config2
  end

  test "ActiveAgent.configure yields configuration" do
    ActiveAgent.configure do |config|
      config.retries = false
      config.retries_count = 99
    end

    assert_equal false, ActiveAgent.configuration.retries
    assert_equal 99, ActiveAgent.configuration.retries_count
  end

  test "ActiveAgent.configure returns configuration" do
    result = ActiveAgent.configure do |config|
      config.retries_count = 42
    end

    assert_instance_of ActiveAgent::Configuration, result
    assert_equal 42, result.retries_count
  end

  test "ActiveAgent.reset_configuration! creates new instance" do
    ActiveAgent.configuration.retries_count = 50
    original = ActiveAgent.configuration

    ActiveAgent.reset_configuration!
    new_config = ActiveAgent.configuration

    refute_same original, new_config
    assert_equal 3, new_config.retries_count # default value
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
        retries_count: 25
        openai:
          service: "OpenAI"
          model: "gpt-4o"
    YAML

    Tempfile.create([ "config", ".yml" ]) do |file|
      file.write(yaml_content)
      file.rewind

      ENV["RAILS_ENV"] = "development"
      ActiveAgent.configuration_load(file.path)

      assert_equal 25, ActiveAgent.configuration.retries_count
      assert_equal "OpenAI", ActiveAgent.configuration[:openai][:service]
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

  # Test retries_on default error classes
  test "retries_on includes network-related errors by default" do
    config = ActiveAgent::Configuration.new

    assert_includes config.retries_on, EOFError
    assert_includes config.retries_on, Errno::ECONNREFUSED
    assert_includes config.retries_on, Errno::ECONNRESET
    assert_includes config.retries_on, Errno::EHOSTUNREACH
    assert_includes config.retries_on, Errno::EINVAL
    assert_includes config.retries_on, Errno::ENETUNREACH
    assert_includes config.retries_on, Errno::ETIMEDOUT
    assert_includes config.retries_on, SocketError
    assert_includes config.retries_on, Timeout::Error
  end

  test "retries_on can be modified" do
    config = ActiveAgent::Configuration.new
    original_count = config.retries_on.size

    config.retries_on << RuntimeError

    assert_equal original_count + 1, config.retries_on.size
    assert_includes config.retries_on, RuntimeError
  end

  # Test DEFAULTS constant
  test "DEFAULTS constant is frozen" do
    assert ActiveAgent::Configuration::DEFAULTS.frozen?
  end

  test "DEFAULTS retries_on is frozen" do
    assert ActiveAgent::Configuration::DEFAULTS[:retries_on].frozen?
  end
end
