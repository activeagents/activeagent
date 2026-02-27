# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module RubyLLM
      # Embedding request model for RubyLLM provider.
      class EmbeddingRequest < Common::BaseModel
        attribute :model, :string
        attribute :input
        attribute :dimensions, :integer
      end
    end
  end
end
