# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Runcrate
      # Configuration options for the Runcrate provider.
      #
      # Extends OpenAI::Options, overriding the base URL to point at
      # Runcrate's OpenAI-compatible inference API and resolving the API key
      # from RUNCRATE_API_KEY. Runcrate does not use organization or project
      # identifiers.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: ENV["RUNCRATE_API_KEY"])
      #
      # @see https://runcrate.ai/docs/models/overview
      # @see https://runcrate.ai/dashboard/api-keys Runcrate API Keys
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://api.runcrate.ai/v1")
        attribute :base_url, :string, as: "https://api.runcrate.ai/v1"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["RUNCRATE_API_KEY"]
        end

        # Not used as part of Runcrate
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
