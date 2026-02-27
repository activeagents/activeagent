# frozen_string_literal: true

module ActiveAgent
  module Providers
    # Provides exception handling for provider operations.
    #
    # This concern implements basic exception handling that allows agents to
    # define custom error handling logic via rescue_from callbacks. The actual
    # retry logic is now handled by the underlying provider gems (ruby-openai,
    # anthropic-rb, etc.) which provide their own retry mechanisms.
    #
    # @example Using exception handler
    #   class MyProvider
    #     include ActiveAgent::Providers::ExceptionHandler
    #
    #     def call
    #       with_exception_handling do
    #         # API call that may fail
    #       end
    #     end
    #   end
    #
    # @example Agent-level error handling
    #   class MyAgent < ActiveAgent::Base
    #     rescue_from SomeError do |exception|
    #       # Handle the error
    #     end
    #   end
    module ExceptionHandler
      extend ActiveSupport::Concern

      included do
        # @!attribute [rw] exception_handler
        #   @return [Proc, nil] Callback for handling exceptions
        attr_internal :exception_handler
      end

      # Configures instance-level exception handling.
      #
      # @param exception_handler [Proc, nil] callback for handling exceptions
      # @return [void]
      def configure_exception_handler(exception_handler: nil)
        self.exception_handler = exception_handler
      end

      # Executes a block with exception handling.
      #
      # @yield Block to execute with exception protection
      # @return [Object] The result of the block execution
      # @raise [StandardError] Any unhandled exception from the block
      #
      # @example Basic usage
      #   with_exception_handling { api_call }
      def with_exception_handling(&block)
        yield
      rescue => exception
        rescue_with_handler(exception) || raise
        nil # Discard handler return value to prevent polluting raw_response
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
    end
  end
end
