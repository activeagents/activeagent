# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "requests/_types"

module ActiveAgent
  module Providers
    module Ollama
      module Embedding
        class Request < Common::BaseModel
          # Model name to generate embeddings from (required)
          attribute :model, :string

          # Input text or list of text to generate embeddings for (required)
          # Can be a string or array of strings
          attribute :input, Requests::InputType.new

          # Truncates the end of each input to fit within context length (optional)
          # Returns error if false and context length is exceeded
          # Defaults to true
          attribute :truncate, :boolean, default: true

          # Additional model parameters listed in the documentation for the Modelfile (optional)
          # such as temperature
          attribute :options, Requests::OptionsType.new

          # Controls how long the model will stay loaded into memory following the request (optional)
          # Default: 5m
          attribute :keep_alive, :string

          # Validations
          validates :model, :input, presence: true

          # Custom validations
          validate :validate_input_format
          validate :validate_input_not_empty

          # To merge over global prompt/model options over
          delegate_attributes :mirostat, :mirostat_eta, :mirostat_tau, :num_ctx, :repeat_last_n, :repeat_penalty,
                              :temperature, :seed, :num_predict, :top_k, :top_p, :min_p,
                              to: :options

          private

          def validate_input_format
            return if input.nil?

            unless input.is_a?(Array)
              errors.add(:input, "must be stored as an array internally")
              return
            end

            # Validate array contents - Ollama only accepts strings
            input.each_with_index do |item, index|
              unless item.is_a?(String)
                errors.add(:input, "array elements must be strings at index #{index}")
                next
              end

              if item.empty?
                errors.add(:input, "cannot contain empty strings at index #{index}")
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
