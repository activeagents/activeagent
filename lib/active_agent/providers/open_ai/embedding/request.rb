# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Embedding
        class Request < Common::BaseModel
          # Input text to embed (required)
          # Can be a string or array of strings or array of token arrays
          # - Must not exceed max input tokens for the model (8192 for all embedding models)
          # - Cannot be an empty string
          # - Arrays must be 2048 dimensions or less
          # - Maximum of 300,000 tokens summed across all inputs in a single request
          attribute :input, Requests::InputType.new

          # Model ID (required)
          attribute :model, :string

          # Number of dimensions for output embeddings (optional)
          # Only supported in text-embedding-3 and later models
          attribute :dimensions, :integer

          # Format for returned embeddings (optional)
          # Can be "float" or "base64"
          attribute :encoding_format, :string, default: "float"

          # Unique identifier for end-user (optional, deprecated)
          # Can help OpenAI monitor and detect abuse
          attribute :user, :string

          # Validations
          validates :input, :model,   presence: true
          validates :encoding_format, inclusion: { in: %w[float base64] }, allow_nil: true
          validates :dimensions,      numericality: { greater_than: 0 },   allow_nil: true

          # Custom validations
          validate :validate_input_format
          validate :validate_input_not_empty

          private

          def validate_input_format
            return if input.nil?

            unless input.is_a?(Array)
              errors.add(:input, "must be stored as an array internally")
              return
            end

            # Validate array contents
            input.each_with_index do |item, index|
              case item
              when String
                if item.empty?
                  errors.add(:input, "cannot contain empty strings at index #{index}")
                end
              when Array
                # Token array validation
                if item.length > 2048
                  errors.add(:input, "token arrays must be 2048 dimensions or less at index #{index}")
                end
                if item.empty?
                  errors.add(:input, "cannot contain empty token arrays at index #{index}")
                end
              else
                errors.add(:input, "array elements must be strings or token arrays at index #{index}")
              end
            end
          end

          def validate_input_not_empty
            return if input.nil?

            if input.is_a?(Array) && input.empty?
              errors.add(:input, "cannot be an empty array")
            end
          end
        end
      end
    end
  end
end
