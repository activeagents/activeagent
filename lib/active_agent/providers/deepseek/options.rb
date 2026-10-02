# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module DeepSeek
      # Configuration options for the DeepSeek provider.
      #
      # Extends OpenAI::Options because DeepSeek serves an OpenAI-compatible
      # API. Only the endpoint and the credential's environment variable differ;
      # DeepSeek has no organization or project scoping.
      #
      # @example Configuration in active_agent.yml
      #   deepseek:
      #     service: "DeepSeek"
      #     api_key: <%= ENV["DEEPSEEK_API_KEY"] %>
      #
      # @example Inline
      #   generate_with :deepseek, model: "deepseek-flash"
      #
      # @see OpenAI::Options
      # @see https://api-docs.deepseek.com
      class Options < OpenAI::Options
        # DeepSeek's OpenAI-compatible endpoint. The Anthropic-compatible one
        # lives at /anthropic and is served by AnthropicProvider instead.
        DEFAULT_BASE_URL = "https://api.deepseek.com"

        # @param kwargs [Hash]
        # @option kwargs [String] :api_key
        # @option kwargs [String] :base_url (https://api.deepseek.com)
        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(kwargs.merge(base_url: kwargs[:base_url].presence || DEFAULT_BASE_URL))
        end

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["DEEPSEEK_API_KEY"] ||
            ENV["DEEPSEEK_ACCESS_TOKEN"]
        end

        # DeepSeek is not an OpenAI organization; scoping one would be a lie.
        def resolve_organization_id(_kwargs) = nil
        def resolve_project_id(_kwargs)      = nil
      end
    end
  end
end
