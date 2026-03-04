require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "gemini/_types"

module ActiveAgent
  module Providers
    # Provides access to Google's Gemini API via OpenAI-compatible endpoint.
    #
    # Extends OpenAI provider to work with Gemini's OpenAI-compatible API,
    # enabling access to Gemini models through a familiar interface.
    #
    # @see OpenAI::ChatProvider
    # @see https://ai.google.dev/gemini-api/docs/openai
    class GeminiProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "Gemini"
      end

      # @return [Class]
      def self.options_klass
        namespace::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        namespace::RequestType.new
      end

      protected

      # Executes chat completion request with Gemini-specific error handling.
      #
      # @see OpenAI::ChatProvider#api_prompt_execute
      # @param parameters [Hash]
      # @return [Object, nil] response object or nil for streaming
      # @raise [OpenAI::Errors::APIConnectionError] when Gemini API unreachable
      def api_prompt_execute(parameters)
        super

      rescue ::OpenAI::Errors::APIConnectionError => exception
        log_connection_error(exception)
        raise exception
      end

      # Merges streaming delta into the message with role cleanup.
      #
      # Overrides parent to handle Gemini's role copying behavior which duplicates
      # the role field in every streaming chunk, requiring manual cleanup to prevent
      # message corruption.
      #
      # @see OpenAI::ChatProvider#message_merge_delta
      # @param message [Hash]
      # @param delta [Hash]
      # @return [Hash]
      def message_merge_delta(message, delta)
        message[:role] = delta.delete(:role) if delta[:role]

        hash_merge_delta(message, delta)
      end

      # Logs connection failures with Gemini API details for debugging.
      #
      # @param error [Exception]
      # @return [void]
      def log_connection_error(error)
        instrument("connection_error.provider.active_agent",
                  uri_base: options.base_url,
                  exception: error.class,
                  message: error.message)
      end
    end
  end
end
