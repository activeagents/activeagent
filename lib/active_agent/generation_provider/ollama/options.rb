# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module GenerationProvider
    module Ollama
      class Options < ActiveAgent::GenerationProvider::OpenAI::Options
        # Client Options
        attribute :uri_base, :string, default: "http://localhost:11434"

        private

        def resolve_access_token(settings)
          settings["api_key"] ||
            settings["access_token"] ||
            ENV["OLLAMA_API_KEY"] ||
            ENV["OLLAMA_ACCESS_TOKEN"]
        end

        # Not Used as Part of Ollama
        def resolve_organization_id(settings) = nil
        def resolve_admin_token(settings)     = nil
      end
    end
  end
end
