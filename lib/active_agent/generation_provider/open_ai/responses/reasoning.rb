# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Responses
        class Reasoning < Common::BaseModel
          # Effort level for reasoning (low, medium, high)
          attribute :effort, :string

          # Summary configuration
          attribute :summary # Can be string or object with format/length

          validates :effort, inclusion: { in: %w[low medium high] }, allow_nil: true
        end
      end
    end
  end
end
