# frozen_string_literal: true

module ActiveAgent
  module Providers
    # Provides retry logic and exception handling for provider operations.
    #
    # This concern implements configurable retry strategies for handling transient
    # failures when communicating with LLM providers. It supports three retry modes:
    # - No retries (false)
    # - Built-in exponential backoff retries (true)
    # - Custom retry strategies (Proc)
    #
    # @example Using built-in retries
    #   class MyProvider
    #     include ActiveAgent::Providers::Retries
    #
    #     def call
    #       retriable do
    #         # API call that may fail
    #       end
    #     end
    #   end
    #
    # @example Custom retry strategy
    #   ActiveAgent.configure do |config|
    #     config.retries = ->(block) do
    #       3.times do |attempt|
    #         break block.call
    #       rescue SomeError
    #         sleep(attempt * 2)
    #         retry if attempt < 2
    #       end
    #     end
    #   end
    module Retries
      extend ActiveSupport::Concern

      included do
        # @!attribute [rw] exception_handler
        #   @return [Proc, nil] Callback for handling exceptions that occur during retries
        # @!attribute [rw] retries
        #   @return [Boolean, Proc] Instance-level retry strategy configuration
        # @!attribute [rw] retries_count
        #   @return [Integer] Maximum number of retry attempts for this instance
        # @!attribute [rw] retries_on
        #   @return [Array<Class>] Array of exception classes to retry on
        attr_internal :exception_handler, :retries, :retries_count, :retries_on

        delegate :retriable_strategy, :retriable_exceptions, :retriable_max, to: :class
      end

      class_methods do
        # Returns the configured retry strategy from global configuration.
        #
        # This class method provides the default retry strategy that can be
        # overridden at the instance level.
        #
        # @return [Boolean, Proc] The retry strategy (true, false, or custom Proc)
        def retriable_strategy
          if (strategy = ActiveAgent.configuration.retries).nil?
            Configuration::DEFAULTS[:retries]
          else
            strategy
          end
        end

        # Returns the global exception configuration for retries.
        #
        # This provides the base set of exception classes that should trigger
        # retries, which can be extended at the instance level.
        #
        # @return [Array<Class>] Array of exception classes to retry on from global config
        def retriable_exceptions
          (ActiveAgent.configuration&.retries_on || Configuration::DEFAULTS[:retries_on])
        end

        # Returns the maximum number of retry attempts from global configuration.
        #
        # This class method provides the default retry count that can be
        # overridden at the instance level.
        #
        # @return [Integer] Maximum retry count from configuration
        def retriable_max
          ActiveAgent.configuration&.retries_count || Configuration::DEFAULTS[:retries_count]
        end
      end

      # Configures instance-level retry behavior.
      #
      # Merges provided options with global configuration defaults.
      # Instance options override global settings. Exception classes are merged
      # (not replaced) with global configuration.
      #
      # @param exception_handler [Proc, nil] callback for handling exceptions
      # @param retries [Boolean, Proc, nil] retry strategy, defaults to global config
      # @param retries_count [Integer, nil] maximum retry attempts, defaults to global config
      # @param retries_on [Array<Class>, nil] additional exception classes to retry on (merged with global)
      # @return [void]
      def configure_retries(exception_handler: nil, retries: nil, retries_count: nil, retries_on: nil)
        self.exception_handler = exception_handler
        self.retries           = retries.nil? ? retriable_strategy : retries
        self.retries_count     = retries_count || retriable_max
        self.retries_on        = retriable_exceptions | (retries_on || [])
      end

      # Executes a block with retry logic based on the configured strategy.
      #
      # The retry strategy is determined by the configuration and can be:
      # - `false`: No retries, only error handling
      # - `true`: Built-in exponential backoff retries
      # - `Proc`: Custom retry strategy
      #
      # @yield Block to execute with retry protection
      # @return [Object] The result of the block execution
      # @raise [StandardError] Any unhandled exception from the block
      #
      # @example Without retries
      #   retriable { api_call }  # With retries disabled
      #
      # @example With built-in retries
      #   retriable { api_call }  # With retries enabled
      #
      # @example With custom strategy
      #   retriable { api_call }  # Using custom Proc strategy
      def retriable(&block)
        case (strategy = retries)
        when false
          # No retries - execute directly with error handling
          retriable_with_rescue(&block)
        when true
          # Built-in retry logic
          retriable_with_builtin_retries(&block)
        else
          # Custom retry wrapper (Proc)
          retriable_with_custom_retries(strategy, &block)
        end
      end

      # Bubbles up exceptions to the Agent's rescue_from if a handler is defined.
      #
      # This method delegates exception handling to the configured exception handler,
      # allowing agents to define custom error handling logic.
      #
      # @param exception [StandardError] The exception to handle
      # @return [Object, nil] Result from the exception handler, or nil if no handler
      def rescue_with_handler(exception)
        exception_handler&.call(exception)
      end

      private

      # Executes a block with basic exception handling (no retries).
      #
      # @yield Block to execute
      # @return [Object] Result of the block execution
      # @raise [StandardError] Re-raises exception if not handled
      # @api private
      def retriable_with_rescue(&block)
        yield
      rescue => exception
        rescue_with_handler(exception) || raise
      end

      # Executes a block with built-in exponential backoff retry logic.
      #
      # Retries the block on configured exceptions up to the maximum retry count,
      # with exponential backoff between attempts (2^(attempt-1) seconds).
      # Uses instance-level configuration for retry count and exception list.
      #
      # @yield Block to execute with retries
      # @return [Object] Result of the block execution
      # @raise [StandardError] Re-raises exception if max retries exceeded or not retriable
      # @api private
      def retriable_with_builtin_retries(&block)
        attempt ||= 0
        yield

      rescue => exception
        attempt += 1

        is_retriable = retries_on.any? { exception.is_a?(it) }

        if is_retriable && attempt <= retries_count
          backoff_time = 2 ** (attempt - 1)
          instrument("retry_attempt.provider.active_agent", attempt:, max_retries: retries_count, exception: exception.class, backoff_time:)
          sleep(backoff_time)
          retry
        end

        if is_retriable && attempt > retries_count
          instrument("retry_exhausted.provider.active_agent", max_retries: retries_count, exception: exception.class)
        end

        rescue_with_handler(exception) || raise
      end

      # Executes a block with a custom retry strategy.
      #
      # Wraps the block with error handling and delegates retry logic to the
      # provided strategy Proc.
      #
      # @param strategy [Proc] Custom retry strategy to execute
      # @yield Block to execute with custom retry logic
      # @return [Object] Result of the block execution
      # @raise [StandardError] Any exception from the strategy or block
      # @api private
      def retriable_with_custom_retries(strategy, &block)
        wrapped_block = proc do
          block.call
        rescue => exception
          rescue_with_handler(exception) || raise
        end

        strategy.call(wrapped_block)
      end
    end
  end
end
