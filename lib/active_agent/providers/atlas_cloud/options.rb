# frozen_string_literal: true

require_relative "../open_ai/options"

module ActiveAgent
  module Providers
    module AtlasCloud
      # Configuration options for the Atlas Cloud provider.
      class Options < ActiveAgent::Providers::OpenAI::Options
        attribute :base_url, :string, as: "https://api.atlascloud.ai/v1"

        private

        def resolve_api_key(kwargs)
          kwargs[:api_key] ||
            kwargs[:access_token] ||
            ENV["ATLASCLOUD_API_KEY"]
        end

        def resolve_organization_id(_kwargs) = nil
        def resolve_project_id(_kwargs) = nil
      end
    end
  end
end
