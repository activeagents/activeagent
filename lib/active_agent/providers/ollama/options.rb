# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Ollama
      class Options < ActiveAgent::Providers::OpenAI::Options
        attribute :base_url, :string, fallback: "http://127.0.0.1:11434/v1"
        attribute :api_key,  :string, fallback: "ollama"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["OLLAMA_API_KEY"] ||
            ENV["OLLAMA_ACCESS_TOKEN"]
        end

        # Not Used as Part of Ollama
        def resolve_organization_id(settings) = nil
        def resolve_project_id(settings)      = nil
      end
    end
  end
end
