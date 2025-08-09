# frozen_string_literal: true

module ActiveAgent
  # = Active Agent Errors
  #
  # This module defines all custom error classes used throughout the ActiveAgent gem.
  # All custom errors inherit from ActiveAgentError which provides a common base
  # for catching any ActiveAgent-specific errors.
  module Errors
    # Base error class for all ActiveAgent errors
    class ActiveAgentError < StandardError; end

    # Base error for all generation provider related errors
    class GenerationProviderError < ActiveAgentError; end

    # Error raised when a provider API returns an error response
    # This includes HTTP errors, API key issues, rate limiting, model not found, etc.
    class ProviderApiError < ActiveAgentError
      attr_reader :provider_name, :status_code, :error_type

      def initialize(message, provider_name: nil, status_code: nil, error_type: nil)
        @provider_name = provider_name
        @status_code = status_code
        @error_type = error_type
        super(message)
      end

      def to_s
        parts = [super]
        parts << "(Provider: #{provider_name})" if provider_name
        parts << "(Status: #{status_code})" if status_code
        parts << "(Type: #{error_type})" if error_type
        parts.join(" ")
      end
    end

    # Error raised when an output schema template cannot be found or loaded
    class SchemaNotFoundError < ActiveAgentError
      attr_reader :schema_name, :prefixes

      def initialize(message = nil, schema_name: nil, prefixes: nil)
        @schema_name = schema_name
        @prefixes = prefixes

        message ||= build_default_message
        super(message)
      end

      private

      def build_default_message
        parts = ["Output schema not found"]
        parts << "for '#{schema_name}'" if schema_name
        parts << "in #{prefixes}" if prefixes && prefixes.any?
        parts.join(" ")
      end
    end
  end
end
