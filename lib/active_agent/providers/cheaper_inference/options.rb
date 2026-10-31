# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module CheaperInference
      # Configuration options for the Cheaper Inference provider.
      #
      # Extends OpenAI::Options, overriding the base URL to point at Cheaper
      # Inference's OpenAI-compatible gateway and resolving the API key from
      # CHEAPER_INFERENCE_API_KEY. Cheaper Inference does not use organization
      # or project identifiers.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: ENV["CHEAPER_INFERENCE_API_KEY"])
      #
      # @see https://cheaperinference.com/docs
      # @see https://cheaperinference.com/signup Cheaper Inference API Keys
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://api.cheaperinference.com/v1")
        attribute :base_url, :string, as: "https://api.cheaperinference.com/v1"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["CHEAPER_INFERENCE_API_KEY"]
        end

        # Not used as part of Cheaper Inference
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
