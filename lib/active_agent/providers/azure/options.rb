# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Azure
      # Configuration options for Azure OpenAI Service.
      #
      # Azure OpenAI uses a different authentication and endpoint structure than standard OpenAI:
      # - Endpoint: https://{resource}.openai.azure.com/openai/deployments/{deployment}/
      # - Authentication: api-key header instead of Authorization: Bearer
      # - API Version: Required query parameter
      #
      # @example Configuration
      #   options = Azure::Options.new(
      #     api_key: ENV["AZURE_OPENAI_API_KEY"],
      #     azure_resource: "mycompany",
      #     deployment_id: "gpt-4-deployment",
      #     api_version: "2024-10-21"
      #   )
      class Options < ActiveAgent::Providers::OpenAI::Options
        DEFAULT_API_VERSION = "2024-10-21"

        attribute :azure_resource, :string
        attribute :deployment_id,  :string
        attribute :api_version,    :string, fallback: DEFAULT_API_VERSION

        validates :azure_resource, presence: true
        validates :deployment_id, presence: true

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)
          kwargs[:api_version] ||= resolve_api_version(kwargs)
          super(kwargs)
        end

        # Returns Azure-specific headers for authentication.
        #
        # Azure uses api-key header instead of Authorization: Bearer.
        #
        # @return [Hash] headers including api-key
        def extra_headers
          { "api-key" => api_key }
        end

        # Returns Azure-specific query parameters.
        #
        # Azure requires api-version as a query parameter.
        #
        # @return [Hash] query parameters including api-version
        def extra_query
          { "api-version" => api_version }
        end

        # Builds the base URL for Azure OpenAI API requests.
        #
        # @return [String] the Azure OpenAI endpoint URL
        def base_url
          "https://#{azure_resource}.openai.azure.com/openai/deployments/#{deployment_id}"
        end

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["AZURE_OPENAI_API_KEY"] ||
            ENV["AZURE_OPENAI_ACCESS_TOKEN"]
        end

        def resolve_api_version(kwargs)
          kwargs[:api_version] ||
            ENV["AZURE_OPENAI_API_VERSION"] ||
            DEFAULT_API_VERSION
        end

        # Not used as part of Azure OpenAI
        def resolve_organization_id(_settings) = nil
        def resolve_project_id(_settings)      = nil
      end
    end
  end
end
