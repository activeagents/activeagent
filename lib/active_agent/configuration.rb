# frozen_string_literal: true

require "active_support/core_ext/object/duplicable"
require "active_support/core_ext/hash/indifferent_access"
require "erb"
require "socket"
require "timeout"
require "yaml"

module ActiveAgent
  # Simple logger wrapper that prepends a tag to all log messages.
  #
  # @private
  class TaggedLogger
    attr_reader :logger, :tag

    def initialize(logger, tag)
      @logger = logger
      @tag = tag
    end

    %i[debug info warn error fatal unknown].each do |method|
      define_method(method) do |message = nil, &block|
        if block_given?
          result = block.call
          logger.public_send(method, "#{tag} #{result}")
        elsif message
          logger.public_send(method, "#{tag} #{message}")
        else
          logger.public_send(method, tag)
        end
      end
    end

    # Delegate all other methods to the logger
    def method_missing(method, *args, &block)
      logger.public_send(method, *args, &block)
    end

    def respond_to_missing?(method, include_private = false)
      logger.respond_to?(method, include_private) || super
    end
  end

  # Configuration class for ActiveAgent global settings.
  #
  # Provides configuration options for generation behavior, error handling,
  # logging, and retry strategies. Configuration can be set globally using
  # the {ActiveAgent.configure} method or loaded from a YAML file for
  # provider-specific settings.
  #
  # = Global Configuration
  #
  # Use {ActiveAgent.configure} for framework-level settings like retry behavior
  # and logging.
  #
  # @example Basic configuration
  #   ActiveAgent.configure do |config|
  #     config.retries = true
  #     config.retries_count = 5
  #   end
  #
  # @example Custom retry strategy
  #   ActiveAgent.configure do |config|
  #     config.retries = ->(block) do
  #       Retriable.retriable(tries: 3, on: [Net::ReadTimeout]) do
  #         block.call
  #       end
  #     end
  #   end
  #
  # = Provider Configuration
  #
  # Use YAML configuration files to define provider-specific settings like
  # API keys, models, and parameters. This is the recommended approach for
  # managing multiple generation providers across different environments.
  #
  # @example YAML configuration file (config/activeagent.yml)
  #   # Define reusable anchors for common settings
  #   openai: &openai
  #     service: "OpenAI"
  #     access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
  #
  #   anthropic: &anthropic
  #     service: "Anthropic"
  #     access_token: <%= Rails.application.credentials.dig(:anthropic, :access_token) %>
  #
  #   development:
  #     openai:
  #       <<: *openai
  #       model: "gpt-4o-mini"
  #       temperature: 0.7
  #     anthropic:
  #       <<: *anthropic
  #       model: "claude-3-5-sonnet-20241022"
  #
  #   production:
  #     openai:
  #       <<: *openai
  #       model: "gpt-4o"
  #       temperature: 0.5
  #
  # @example Loading provider configuration
  #   # In config/initializers/activeagent.rb
  #   ActiveAgent.configuration_load(Rails.root.join("config/activeagent.yml"))
  #
  # @example Using configured providers in agents
  #   class MyAgent < ActiveAgent::Base
  #     generate_with :openai  # Uses settings from config/activeagent.yml
  #   end
  #
  # @see ActiveAgent.configure
  # @see ActiveAgent.configuration_load
  class Configuration
    # Default configuration values.
    #
    # @return [Hash] Hash of default configuration values
    DEFAULTS = {
      verbose_generation_errors: false,
      colorize_logging: true,
      retries: true,
      retries_count: 3,
      retries_on: [
        EOFError,
        Errno::ECONNREFUSED,
        Errno::ECONNRESET,
        Errno::EHOSTUNREACH,
        Errno::EINVAL,
        Errno::ENETUNREACH,
        Errno::ETIMEDOUT,
        SocketError,
        Timeout::Error
      ].freeze
    }.freeze

    # @!attribute [rw] verbose_generation_errors
    #   When true, generation errors will include detailed error messages and backtraces.
    #   @return [Boolean] Whether to show verbose error messages (default: false)
    attr_accessor :verbose_generation_errors

    # @!attribute [rw] colorize_logging
    #   When true, log subscriber output will be colorized.
    #   @return [Boolean] Whether to colorize log output (default: true)
    attr_accessor :colorize_logging

    # Returns the logger instance, creating a default one if not set.
    #
    # @return [Logger] Logger instance (defaults to Logger.new(STDOUT) if not set)
    def logger
      @logger ||= begin
        base_logger = Logger.new(STDOUT)
        base_logger.level = Logger::INFO
        TaggedLogger.new(base_logger, "[ActiveAgent]")
      end
    end

    # Sets the logger instance.
    #
    # When set to false, creates a null logger that discards all output.
    #
    # @param value [Logger, false] Logger instance to use, or false to disable logging
    # @return [Logger] The logger that was set
    def logger=(value)
      base_logger = if value == false
        Logger.new(IO::NULL)
      else
        value
      end
      @logger = TaggedLogger.new(base_logger, "[ActiveAgent]")
    end

    # Returns the current log level of the logger.
    #
    # @return [Integer, Symbol] The current log level
    def log_level
      logger.level
    end

    # Sets the log level on the logger instance.
    #
    # @param level [Integer, Symbol] The log level to set (e.g., :debug, :info, :warn, :error)
    # @return [Integer] The log level that was set
    def log_level=(level)
      logger.level = level
    end

    # @!attribute [rw] retries
    #   Retry strategy for generation requests.
    #   Can be false (no retries), true (built-in retries), or a Proc for custom logic.
    #   @return [Boolean, Proc] Retry strategy (default: true)
    #   @see #retries=
    attr_accessor :retries

    # @!attribute [rw] retries_count
    #   Maximum number of retry attempts for generation requests.
    #   @return [Integer] Maximum retry attempts (default: 3)
    attr_accessor :retries_count

    # @!attribute [rw] retries_on
    #   Array of exception classes that should trigger retries.
    #   Only used when {#retries} is set to true (built-in retry logic).
    #   @return [Array<Class>] Exception classes to retry on (default: network-related errors)
    #   @see #retries
    #   @see #retries_count
    attr_accessor :retries_on

    # Loads configuration from a YAML file.
    #
    # Reads a YAML configuration file, evaluates any ERB templates, and extracts
    # environment-specific settings based on RAILS_ENV or ENV environment variables.
    # Falls back to the root level settings if no environment key is found.
    #
    # The YAML file can contain both framework-level settings (retries, logging, etc.)
    # and provider-specific configurations (API keys, models, parameters). Provider
    # configurations are stored as nested hashes and can be accessed via the [] operator.
    #
    # @param filename [String] Path to the YAML configuration file
    # @return [Configuration] A new Configuration instance with loaded settings
    #
    # @example Framework settings only
    #   # config/activeagent.yml
    #   development:
    #     retries: true
    #     retries_count: 3
    #   production:
    #     retries: true
    #     retries_count: 5
    #     verbose_generation_errors: false
    #
    # @example Provider-specific configuration with YAML anchors
    #   # config/activeagent.yml
    #   openai: &openai
    #     service: "OpenAI"
    #     access_token: <%= Rails.application.credentials.dig(:openai, :access_token) %>
    #     retries: false
    #
    #   anthropic: &anthropic
    #     service: "Anthropic"
    #     access_token: <%= Rails.application.credentials.dig(:anthropic, :access_token) %>
    #
    #   open_router: &open_router
    #     service: "OpenRouter"
    #     access_token: <%= Rails.application.credentials.dig(:open_router, :access_token) %>
    #     retries_count: 5
    #
    #   development:
    #     openai:
    #       <<: *openai
    #       model: "gpt-4o-mini"
    #       temperature: 0.7
    #     anthropic:
    #       <<: *anthropic
    #       model: "claude-3-5-sonnet-20241022"
    #     open_router:
    #       <<: *open_router
    #       model: "qwen/qwen3-30b-a3b:free"
    #
    #   test:
    #     openai:
    #       <<: *openai
    #       model: "gpt-4o-mini"
    #     anthropic:
    #       <<: *anthropic
    #
    #   production:
    #     openai:
    #       <<: *openai
    #       model: "gpt-4o"
    #       temperature: 0.5
    #     anthropic:
    #       <<: *anthropic
    #       model: "claude-3-5-sonnet-20241022"
    #
    # @example Loading and accessing provider configuration
    #   config = ActiveAgent::Configuration.load("config/activeagent.yml")
    #   config[:openai]  # => { "service" => "OpenAI", "model" => "gpt-4o-mini", ... }
    #
    # @note ERB templates are evaluated, allowing you to use Rails credentials,
    #   environment variables, or any Ruby code within <%= %> tags.
    def self.load(filename)
      settings = {}

      if File.exist?(filename)
        config_file = YAML.load(ERB.new(File.read(filename)).result, aliases: true)
        env         = ENV["RAILS_ENV"] || ENV["ENV"] || "development"
        settings    = config_file[env] || config_file
      end

      Configuration.new(settings)
    end

    # Initializes a new Configuration instance with default values.
    #
    # Sets all configuration attributes to their default values as defined
    # in {DEFAULTS}. Duplicates values where possible to prevent shared state.
    # Custom settings can be passed to override defaults.
    #
    # When loading from a YAML file via {Configuration.load}, all settings from
    # the environment-specific section are passed as the settings hash, including
    # any provider configurations defined in the file.
    #
    # @param settings [Hash] Optional settings to override defaults
    # @option settings [Boolean] :verbose_generation_errors (false) Enable verbose errors
    # @option settings [Boolean, Proc] :retries (true) Retry strategy
    # @option settings [Integer] :retries_count (3) Maximum retry attempts
    # @option settings [Array<Class>] :retries_on Network error classes to retry on
    #
    # @example With default settings
    #   config = ActiveAgent::Configuration.new
    #
    # @example With custom settings
    #   config = ActiveAgent::Configuration.new(
    #     retries: false,
    #     verbose_generation_errors: true
    #   )
    #
    # @example With provider configurations (typically from YAML)
    #   config = ActiveAgent::Configuration.new(
    #     openai: { service: "OpenAI", model: "gpt-4o" },
    #     anthropic: { service: "Anthropic", model: "claude-3-5-sonnet-20241022" }
    #   )
    def initialize(settings = {})
      (DEFAULTS.merge(settings)).each do |key, value|
        self[key] = value
      end
    end

    # Checks if verbose generation errors are enabled.
    #
    # @return [Boolean] True if verbose errors are enabled
    def verbose_generation_errors?
      @verbose_generation_errors
    end

    # Configures the retry strategy for generation requests.
    #
    # @param strategy [Boolean, Proc]
    #   - false: disables retries completely
    #   - true: uses built-in retry logic (default)
    #   - Proc: custom retry wrapper that receives a block to execute
    #
    # @raise [ArgumentError] If strategy is not false, true, or a callable object
    #
    # @example Disable retries
    #   config.retries = false
    #
    # @example Use built-in retries (default)
    #   config.retries = true
    #
    # @example Custom retry wrapper with Retriable gem
    #   config.retries = ->(block) {
    #     Retriable.retriable(tries: 5, on: [Net::ReadTimeout, Timeout::Error]) do
    #       block.call
    #     end
    #   }
    #
    # @example Circuit breaker pattern
    #   config.retries = ->(block) {
    #     CircuitBreaker.handle do
    #       block.call
    #     end
    #   }
    #
    # @see #retries_count
    # @see #retries_on
    def retries=(strategy)
      unless strategy == false || strategy == true || strategy.respond_to?(:call)
        raise ArgumentError, "retries must be false, true, or a callable object (Proc/Lambda)"
      end
      @retries = strategy
    end

    # Retrieves a configuration value by key.
    #
    # This method provides hash-like access to both framework settings and
    # provider configurations. Framework settings correspond to the defined
    # accessors, while provider configurations are stored as nested hashes.
    #
    # @param key [String, Symbol] Configuration key to retrieve
    # @return [Object, nil] The configuration value or nil if not found
    #
    # @example Accessing framework settings
    #   config[:retries]  # => true
    #   config["retries"] # => true
    #
    # @example Accessing provider configurations
    #   config[:openai]     # => { "service" => "OpenAI", "model" => "gpt-4o", ... }
    #   config[:anthropic]  # => { "service" => "Anthropic", "model" => "claude-3-5-sonnet-20241022", ... }
    def [](key)
      instance_variable_get("@#{key}")
    end

    # Sets a configuration value by key.
    #
    # @param key [String, Symbol] Configuration key to set
    # @param value [Object] Value to set
    # @return [Object] The value that was set
    #
    # @example
    #   config[:retries] = false
    #   config["retries_count"] = 5
    def []=(key, value)
      instance_variable_set("@#{key}", convert_to_indifferent_access(value))
    end

    # Extracts nested values using a sequence of keys.
    #
    # Similar to Hash#dig, traverses nested configuration values safely.
    # Returns nil if any intermediate key doesn't exist.
    #
    # @param keys [Array<String, Symbol>] Keys to traverse
    # @return [Object, nil] The nested value or nil
    #
    # @example
    #   config.dig(:openai, :model)  # => "gpt-4o"
    #   config.dig("test", "anthropic", "service")  # => "Anthropic"
    #   config.dig(:nonexistent, :key)  # => nil
    def dig(*keys)
      keys.reduce(self) do |obj, key|
        break nil unless obj
        if obj.is_a?(Configuration)
          obj[key]
        elsif obj.respond_to?(:dig)
          obj.dig(key)
        elsif obj.respond_to?(:[])
          obj[key]
        else
          nil
        end
      end
    end

    # Creates a deep duplicate of the configuration.
    #
    # Recursively duplicates all configuration values to avoid shared state.
    #
    # @return [Configuration] A new Configuration instance with duplicated values
    #
    # @example
    #   original = ActiveAgent.configuration
    #   backup = original.deep_dup
    #   backup[:retries] = false  # doesn't affect original
    def deep_dup
      new_config = Configuration.new
      instance_variables.each do |var|
        value = instance_variable_get(var)
        new_config.instance_variable_set(var, deep_dup_value(value))
      end
      new_config
    end

    # Replaces the current configuration values with those from another configuration.
    #
    # Copies all instance variables from the source configuration to this one,
    # and removes any instance variables that exist in self but not in other.
    # Useful for restoring configuration state in tests.
    #
    # @param other [Configuration] The configuration to copy from
    # @return [Configuration] Self
    #
    # @example
    #   backup = config.deep_dup
    #   # ... make changes ...
    #   config.replace(backup)  # restore original state
    def replace(other)
      # Remove variables that exist in self but not in other
      (instance_variables - other.instance_variables).each do |var|
        remove_instance_variable(var)
      end

      # Copy all variables from other to self
      other.instance_variables.each do |var|
        instance_variable_set(var, other.instance_variable_get(var))
      end

      self
    end

    # Delegates method calls to the [] operator for accessing configuration values.
    #
    # Allows accessing configuration values using method syntax instead of
    # hash-like access. Returns nil for undefined configuration keys.
    #
    # @param method [Symbol] The method name (configuration key)
    # @param args [Array] Method arguments (not used)
    # @return [Object, nil] The configuration value or nil
    # @private
    #
    # @example
    #   config.retries        # => true (same as config[:retries])
    #   config.retries_count  # => 3 (same as config[:retries_count])
    def method_missing(method, *args)
      self[method]
    end

    # Checks if the configuration responds to a method.
    #
    # Returns true if an instance variable exists for the given method name,
    # allowing proper introspection of dynamically accessible configuration keys.
    #
    # @param method [Symbol] The method name to check
    # @param include_private [Boolean] Whether to include private methods
    # @return [Boolean] True if the configuration has the key
    # @private
    def respond_to_missing?(method, include_private = false)
      instance_variable_defined?("@#{method}") || super
    end

    private

    # Recursively converts hashes to HashWithIndifferentAccess.
    #
    # This ensures that all hash values (including nested hashes) can be
    # accessed using both string and symbol keys. Non-hash values are
    # returned unchanged.
    #
    # @param value [Object] The value to convert
    # @return [Object] The converted value
    # @private
    def convert_to_indifferent_access(value)
      case value
      when Hash
        value.with_indifferent_access.transform_values { |v| convert_to_indifferent_access(v) }
      when Array
        value.map { |v| convert_to_indifferent_access(v) }
      else
        value
      end
    end

    # Recursively duplicates a value.
    #
    # Creates deep copies of hashes and arrays to avoid shared state.
    # Uses dup for duplicable objects, returns non-duplicable objects as-is.
    #
    # @param value [Object] The value to duplicate
    # @return [Object] The duplicated value
    # @private
    def deep_dup_value(value)
      case value
      when Hash
        value.transform_values { |v| deep_dup_value(v) }
      when Array
        value.map { |v| deep_dup_value(v) }
      else
        value.duplicable? ? value.dup : value
      end
    end
  end

  # Returns the global configuration instance.
  #
  # Creates a new {Configuration} instance if one doesn't exist.
  #
  # @return [Configuration] The global configuration instance
  #
  # @example Access configuration
  #   ActiveAgent.configuration.retries  # => true
  def self.configuration
    @configuration ||= Configuration.new
  end

  # Configures ActiveAgent with a block.
  #
  # Yields the global configuration instance to the provided block,
  # allowing settings to be modified. This is the recommended way
  # to configure ActiveAgent.
  #
  # @yield [config] Yields the configuration instance
  # @yieldparam config [Configuration] The configuration to modify
  # @return [Configuration] The modified configuration instance
  #
  # @example Basic configuration
  #   ActiveAgent.configure do |config|
  #     config.retries = false
  #     config.verbose_generation_errors = true
  #   end
  #
  # @example Configuring retry behavior
  #   ActiveAgent.configure do |config|
  #     config.retries = true
  #     config.retries_count = 5
  #     config.retries_on << CustomNetworkError
  #   end
  #
  # @example Custom logger
  #   ActiveAgent.configure do |config|
  #     config.logger = Rails.logger
  #     config.log_level = :debug
  #   end
  #
  # @example Disable logging
  #   ActiveAgent.configure do |config|
  #     config.logger = false
  #   end
  def self.configure
    yield configuration if block_given?
    configuration
  end

  # Resets the global configuration to default values.
  #
  # Creates a new {Configuration} instance with all defaults restored.
  # Useful for testing or resetting state.
  #
  # @return [Configuration] The new default configuration instance
  #
  # @example
  #   ActiveAgent.reset_configuration!
  def self.reset_configuration!
    @configuration = Configuration.new
  end

  # Loads and sets the global configuration from a YAML file.
  #
  # Reads configuration from the specified file and sets it as the
  # global configuration instance. This is an alternative to using
  # {.configure} with a block and is the recommended approach for
  # managing provider-specific settings.
  #
  # The YAML file supports ERB templating, environment-specific sections,
  # and YAML anchors for reusing common configuration blocks across providers.
  #
  # @param filename [String] Path to the YAML configuration file
  # @return [Configuration] The loaded configuration instance
  #
  # @example Basic usage in Rails initializer
  #   # config/initializers/activeagent.rb
  #   ActiveAgent.configuration_load(Rails.root.join("config/activeagent.yml"))
  #
  # @example Complete workflow
  #   # 1. Create config/activeagent.yml with provider settings
  #   # 2. Load in initializer:
  #   ActiveAgent.configuration_load("config/activeagent.yml")
  #
  #   # 3. Use in your agents:
  #   class MyAgent < ActiveAgent::Base
  #     generate_with :openai  # Automatically uses config from YAML
  #   end
  #
  # @example Accessing loaded provider configuration
  #   ActiveAgent.configuration[:openai]
  #   # => { "service" => "OpenAI", "model" => "gpt-4o-mini", "temperature" => 0.7, ... }
  #
  # @note This method is typically called once during application initialization.
  #   Store API keys in Rails credentials rather than directly in the YAML file.
  #
  # @see Configuration.load
  # @see .configure
  def self.configuration_load(filename)
    @configuration = Configuration.load(filename)
  end

  # Returns the global logger instance from configuration.
  #
  # Delegates to the configuration's logger, which defaults to Logger.new(STDOUT)
  # if not explicitly set.
  #
  # @return [Logger] The logger instance
  #
  # @example Access global logger
  #   ActiveAgent.logger.info "Processing request"
  #
  # @example Set custom logger
  #   ActiveAgent.configure do |config|
  #     config.logger = Rails.logger
  #   end
  #   ActiveAgent.logger.debug "Debug message"
  #
  # @example Disable logging
  #   ActiveAgent.configure do |config|
  #     config.logger = false
  #   end
  #   ActiveAgent.logger.info "This will not output anything"
  def self.logger
    configuration.logger
  end
end
