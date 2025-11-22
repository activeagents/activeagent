require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "open_router/_types"

module ActiveAgent
  module Providers
    # Provides access to OpenRouter's multi-model API.
    #
    # Extends OpenAI provider to work with OpenRouter's OpenAI-compatible API,
    # enabling access to multiple AI models through a single interface with
    # model fallbacks, cost tracking, and provider metadata.
    #
    # @see OpenAI::ChatProvider
    # @see https://openrouter.ai/docs
    class OpenRouterProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "OpenRouter"
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

      # @see BaseProvider#prepare_prompt_request
      # @return [Request]
      def prepare_prompt_request
        prepare_prompt_request_tools
        super
      end

      # Returns true if tool_choice == "any" (OpenRouter's equivalent of "required").
      #
      # @return [Boolean]
      def tool_choice_forces_required?
        request.tool_choice == "any"
      end

      # Merges streaming delta into the message with role cleanup.
      #
      # Overrides parent to handle OpenRouter's role copying behavior which duplicates
      # the role field in every streaming chunk, requiring manual cleanup to prevent
      # message corruption.
      #
      # @see OpenAI::ChatProvider#message_merge_delta
      # @param message [Hash]
      # @param delta [Hash]
      # @return [Hash]
      def message_merge_delta(message, delta)
        message[:role] = delta.delete(:role) if delta[:role] # Copy a Bad Design (OpenAI's Chat API) Badly, Win Bad Prizes

        hash_merge_delta(message, delta)
      end

      # @see BaseProvider#api_response_normalize
      # @param api_response [OpenAI::Models::ChatCompletion]
      # @return [Hash] normalized response hash
      def api_response_normalize(api_response)
        return api_response unless api_response

        OpenAI::Chat::Transforms.gem_to_hash(api_response)
      end
    end
  end
end
