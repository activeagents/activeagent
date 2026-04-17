# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Gemini
      # Configuration options for Gemini provider
      #
      # Extends OpenAI::Options with Gemini-specific settings including
      # the default base URL for Gemini's OpenAI-compatible API endpoint.
      #
      # @example Basic configuration
      #   options = Options.new(api_key: 'your-api-key')
      #
      # @example With environment variable
      #   # Set GEMINI_API_KEY or GOOGLE_API_KEY
      #   options = Options.new({})
      #
      # @see https://ai.google.dev/gemini-api/docs/openai
      class Options < ActiveAgent::Providers::OpenAI::Options
        GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/openai/"

        attribute :base_url, :string, fallback: GEMINI_BASE_URL

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["GEMINI_API_KEY"] ||
            ENV["GOOGLE_API_KEY"]
        end

        # Not used as part of Gemini
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil
      end
    end
  end
end
