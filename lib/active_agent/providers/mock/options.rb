# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Mock
      # Configuration options for the Mock provider.
      #
      # This provider doesn't make real API calls, so most options are unused.
      # Included for consistency with other providers.
      class Options < Common::BaseModel
        attribute :base_url, :string, default: "https://mock.example.com"
        attribute :api_key, :string, default: "mock-api-key"

        # Common Interface Compatibility
        alias_attribute :access_token, :api_key

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)
          super(**deep_compact(kwargs))
        end

        def serialize
          super
        end
      end
    end
  end
end
