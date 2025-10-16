# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module Ollama
      class Options < ActiveAgent::Providers::OpenAI::Options
        attribute :uri_base,     :string, fallback: "http://127.0.0.1:11434"
        attribute :access_token, :string, fallback: "ollama"

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
