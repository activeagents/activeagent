# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module CloudGPU
      # Configuration options for the CloudGPU provider.
      #
      # Extends OpenAI::Options, overriding the base URL to point at
      # CloudGPU's OpenAI-compatible model API and resolving the API key from
      # CLOUDGPU_API_KEY. CloudGPU does not use organization or project
      # identifiers.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: ENV["CLOUDGPU_API_KEY"])
      #
      # @see https://cloudgpu.app
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://cloudgpu.app/v1")
        attribute :base_url, :string, as: "https://cloudgpu.app/v1"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["CLOUDGPU_API_KEY"]
        end

        # Not used as part of CloudGPU
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
