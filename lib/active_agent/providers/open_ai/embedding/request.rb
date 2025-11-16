# frozen_string_literal: true

require "json"
require_relative "transforms"

module ActiveAgent
  module Providers
    module OpenAI
      module Embedding
        # Wraps OpenAI gem's EmbeddingCreateParams with normalization
        #
        # Delegates to OpenAI::Models::EmbeddingCreateParams while providing
        # parameter normalization via the Transforms module
        class Request < SimpleDelegator
          # Default parameter values applied during initialization
          DEFAULTS = {}.freeze

          # Creates a new embedding request
          #
          # @param params [Hash] embedding parameters
          # @option params [String, Array<String>, Array<Integer>, Array<Array<Integer>>] :input
          #   text or token array(s) to embed
          # @option params [String] :model embedding model identifier
          # @option params [Integer, nil] :dimensions number of dimensions for output (text-embedding-3 only)
          # @option params [String, nil] :encoding_format "float" or "base64"
          # @option params [String, nil] :user unique user identifier
          # @raise [ArgumentError] when parameters are invalid
          def initialize(**params)
            # Step 1: Normalize parameters
            params = Transforms.normalize_params(params)

            # Step 2: Create gem model - this validates all parameters!
            gem_model = ::OpenAI::Models::EmbeddingCreateParams.new(**params)

            # Step 3: Delegate all method calls to gem model
            super(gem_model)
          rescue ArgumentError => e
            # Re-raise with more context
            raise ArgumentError, "Invalid OpenAI Embedding request parameters: #{e.message}"
          end

          # Serializes request for API submission
          #
          # @return [Hash] cleaned request hash without nil values
          def serialize
            serialized = Transforms.gem_to_hash(__getobj__)
            Transforms.cleanup_serialized_request(serialized, DEFAULTS, __getobj__)
          end
        end
      end
    end
  end
end
