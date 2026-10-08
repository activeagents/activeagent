# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Opper
      # Configuration options for the Opper provider.
      #
      # Extends OpenAI::Options, overriding the base URL to point at Opper's
      # OpenAI-compatible gateway and resolving the API key from OPPER_API_KEY.
      # Opper does not use organization or project identifiers.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: ENV["OPPER_API_KEY"])
      #
      # @see https://docs.opper.ai
      # @see https://platform.opper.ai Opper API Keys
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://api.opper.ai/v3/compat")
        attribute :base_url, :string, as: "https://api.opper.ai/v3/compat"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["OPPER_API_KEY"]
        end

        # Not used as part of Opper
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
