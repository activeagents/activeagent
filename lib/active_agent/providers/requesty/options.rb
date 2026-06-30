# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Requesty
      # Configuration options for the Requesty provider.
      #
      # Extends OpenAI::Options, overriding the base URL to point at Requesty's
      # OpenAI-compatible gateway and resolving the API key from REQUESTY_API_KEY.
      # Requesty does not use organization or project identifiers.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: ENV["REQUESTY_API_KEY"])
      #
      # @see https://docs.requesty.ai
      # @see https://app.requesty.ai/api-keys Requesty API Keys
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://router.requesty.ai/v1")
        attribute :base_url, :string, as: "https://router.requesty.ai/v1"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["REQUESTY_API_KEY"] ||
            ENV["REQUESTY_ACCESS_TOKEN"]
        end

        # Not used as part of Requesty
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
