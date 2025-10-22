# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Mock
      # Embedding request model for Mock provider.
      class EmbeddingRequest < Common::BaseModel
        attribute :model, :string, default: "mock-embedding-model"
        attribute :input # String or array of strings to embed
        attribute :encoding_format, :string
        attribute :dimensions, :integer
      end
    end
  end
end
