require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "open_router/_types"

module ActiveAgent
  module Providers
    # Provider implementation for OpenRouter's multi-model API.
    #
    # Extends OpenAI::ChatProvider to work with OpenRouter's OpenAI-compatible API.
    # Provides access to multiple AI models through a single interface with features
    # like model fallbacks, cost tracking, and provider metadata.
    #
    # @see OpenAI::ChatProvider
    # @see https://openrouter.ai/docs
    class OpenRouterProvider < OpenAI::ChatProvider
      def service_name        = "OpenRouter"
      def options_klass       = namespace::Options
      def prompt_request_type = namespace::RequestType.new

      protected

      # Merges streaming delta into the message.
      #
      # Handles OpenRouter's role copying behavior which mimics OpenAI's design.
      #
      # @param message [Hash] The current message being built
      # @param delta [Hash] The delta to merge into the message
      # @return [Hash] The merged message
      def message_merge_delta(message, delta)
        message[:role] = delta.delete(:role) if delta[:role] # Copy a Bad Design (OpenAI's Chat API) Badly, Win Bad Prizes

        hash_merge_delta(message, delta)
      end
    end
  end
end
