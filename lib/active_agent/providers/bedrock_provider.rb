# frozen_string_literal: true

require_relative "anthropic_provider"
require_relative "bedrock/_types"

module ActiveAgent
  module Providers
    # Provider for Anthropic models hosted on AWS Bedrock.
    #
    # Inherits all functionality from AnthropicProvider (streaming, tool use,
    # multimodal, JSON format emulation) and overrides only the client
    # construction to use Anthropic::BedrockClient for AWS authentication.
    #
    # @example Configuration in active_agent.yml
    #   bedrock:
    #     service: "Bedrock"
    #     aws_region: "eu-west-2"
    #     model: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
    #
    # @example Agent usage
    #   class SummaryAgent < ApplicationAgent
    #     generate_with :bedrock, model: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
    #
    #     def summarize
    #       prompt(message: params[:message])
    #     end
    #   end
    #
    # @see AnthropicProvider
    class BedrockProvider < AnthropicProvider
      # @return [String]
      def self.service_name
        "Bedrock"
      end

      # @return [Class]
      def self.options_klass
        Bedrock::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        Anthropic::RequestType.new
      end

      # Returns a configured Bedrock client using AWS credentials.
      #
      # Uses Anthropic::BedrockClient which handles SigV4 signing,
      # credential resolution, and Bedrock URL path rewriting internally.
      #
      # @return [Anthropic::Helpers::Bedrock::Client]
      def client
        @client ||= ::Anthropic::BedrockClient.new(
          aws_region:        options.aws_region,
          aws_access_key:    options.aws_access_key,
          aws_secret_key:    options.aws_secret_key,
          aws_session_token: options.aws_session_token,
          aws_profile:       options.aws_profile,
          base_url:          options.base_url.presence,
          max_retries:       options.max_retries,
          timeout:           options.timeout
        )
      end
    end
  end
end
