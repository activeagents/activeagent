# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module StandardCompute
      # Configuration options for the Standard Compute provider.
      #
      # Extends OpenAI::Options, overriding the base URL to point at
      # Standard Compute's OpenAI-compatible API and resolving the API key
      # from STANDARDCOMPUTE_API_KEY. Standard Compute does not use
      # organization or project identifiers.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: ENV["STANDARDCOMPUTE_API_KEY"])
      #
      # @see https://standardcompute.com
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://api.stdcmpt.com/v1")
        attribute :base_url, :string, as: "https://api.stdcmpt.com/v1"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["STANDARDCOMPUTE_API_KEY"]
        end

        # Not used as part of Standard Compute
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
