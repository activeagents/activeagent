# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module AtlasCloud
      # Configuration options for the Atlas Cloud provider.
      class Options < ActiveAgent::Providers::OpenAI::Options
        # Atlas Cloud's OpenAI-compatible endpoint.
        DEFAULT_BASE_URL = "https://api.atlascloud.ai/v1"

        # @param kwargs [Hash]
        # @option kwargs [String] :api_key
        # @option kwargs [String] :base_url (https://api.atlascloud.ai/v1)
        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(kwargs.merge(base_url: kwargs[:base_url].presence || DEFAULT_BASE_URL))
        end

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["ATLASCLOUD_API_KEY"]
        end

        def resolve_organization_id(_kwargs) = nil
        def resolve_project_id(_kwargs) = nil
      end
    end
  end
end
