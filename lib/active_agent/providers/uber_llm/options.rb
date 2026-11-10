# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module UberLLM
      # Configuration options for the UberLLM provider.
      #
      # Extends OpenAI::Options, overriding the base URL to point at UberLLM's
      # OpenAI-compatible API and resolving the API key from UBERLLM_API_KEY.
      # UberLLM does not use organization or project identifiers.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: ENV["UBERLLM_API_KEY"])
      #
      # @see https://uberllm.dev/docs
      # @see https://uberllm.dev/dashboard/keys UberLLM API Keys
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://api.uberllm.dev/v1")
        attribute :base_url, :string, as: "https://api.uberllm.dev/v1"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["UBERLLM_API_KEY"]
        end

        # Not used as part of UberLLM
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
