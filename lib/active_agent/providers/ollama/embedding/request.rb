# frozen_string_literal: true

require "delegate"
require "json"
require_relative "transforms"

module ActiveAgent
  module Providers
    module Ollama
      module Embedding
        # Wraps OpenAI gem's EmbeddingCreateParams with Ollama-specific extensions
        #
        # Delegates to OpenAI::Models::EmbeddingCreateParams for OpenAI-compatible
        # parameters while adding support for Ollama-specific features like options,
        # keep_alive, and truncate.
        #
        # Ollama-specific parameters:
        # - options: Additional model parameters (Hash with temperature, seed, etc.)
        # - keep_alive: Controls how long model stays in memory (String duration)
        # - truncate: Truncates input to fit context length (Boolean)
        #
        # @example Basic usage
        #   request = Request.new(
        #     model: "llama2",
        #     input: "Hello world"
        #   )
        #
        # @example With Ollama-specific features
        #   request = Request.new(
        #     model: "llama2",
        #     input: ["Hello", "World"],
        #     options: {temperature: 0.7, seed: 42},
        #     keep_alive: "10m",
        #     truncate: false
        #   )
        #
        # @example With delegated option attributes
        #   request = Request.new(
        #     model: "llama2",
        #     input: "Hello",
        #     temperature: 0.7,  # Automatically goes to options
        #     seed: 42           # Automatically goes to options
        #   )
        class Request < SimpleDelegator
          # Default parameter values
          DEFAULTS = {
            truncate: true,
            keep_alive: "5m"
          }.freeze

          # @return [Hash] Ollama-specific parameters
          attr_reader :ollama_params

          # Creates a new Ollama embedding request
          #
          # @param params [Hash] request parameters
          # @option params [String] :model model identifier (required)
          # @option params [String, Array<String>] :input text to embed (required)
          # @option params [Hash] :options model-specific options
          # @option params [String] :keep_alive memory duration
          # @option params [Boolean] :truncate truncate to context length
          # @option params [Float] :temperature delegated to options
          # @option params [Integer] :seed delegated to options
          # @raise [ArgumentError] when parameters are invalid
          def initialize(**params)
            # Step 1: Apply defaults
            params = apply_defaults(params)

            # Step 2: Validate presence of required params before normalization
            raise ArgumentError, "model is required" unless params[:model]
            raise ArgumentError, "input is required" unless params[:input]

            # Step 3: Normalize parameters and split into OpenAI vs Ollama-specific
            openai_params, @ollama_params = Transforms.normalize_params(params)

            # Step 4: Create gem model with OpenAI-compatible params
            gem_model = ::OpenAI::Models::EmbeddingCreateParams.new(**openai_params)

            # Step 5: Delegate to the gem model
            super(gem_model)
          rescue ArgumentError => e
            raise ArgumentError, "Invalid Ollama Embedding request parameters: #{e.message}"
          end

          # Serializes request for API submission
          #
          # Merges OpenAI-compatible parameters with Ollama-specific extensions.
          #
          # @return [Hash] cleaned request hash
          def serialize
            # Get OpenAI params from gem model
            openai_hash = Transforms.gem_to_hash(__getobj__)

            # Merge with Ollama-specific params
            Transforms.cleanup_serialized_request(openai_hash, @ollama_params, DEFAULTS)
          end

          # Accessor for input parameter
          #
          # @return [Array<String>, nil]
          def input
            __getobj__.instance_variable_get(:@data)[:input]
          end

          # Sets input with normalization
          #
          # @param value [String, Array<String>]
          # @return [void]
          def input=(value)
            normalized_value = Transforms.normalize_input(value)
            __getobj__.instance_variable_get(:@data)[:input] = normalized_value
          end

          # Accessor for Ollama options parameter
          #
          # @return [Hash, nil]
          def options
            @ollama_params[:options]
          end

          # Sets options parameter
          #
          # @param value [Hash]
          # @return [void]
          def options=(value)
            @ollama_params[:options] = value
          end

          # Accessor for keep_alive parameter
          #
          # @return [String, nil]
          def keep_alive
            @ollama_params[:keep_alive] || DEFAULTS[:keep_alive]
          end

          # Sets keep_alive parameter
          #
          # @param value [String]
          # @return [void]
          def keep_alive=(value)
            @ollama_params[:keep_alive] = value
          end

          # Accessor for truncate parameter
          #
          # @return [Boolean]
          def truncate
            @ollama_params.fetch(:truncate, DEFAULTS[:truncate])
          end

          # Sets truncate parameter
          #
          # @param value [Boolean]
          # @return [void]
          def truncate=(value)
            @ollama_params[:truncate] = value
          end

          # Delegated option attribute accessors
          # These allow setting option values at the top level
          %i[mirostat mirostat_eta mirostat_tau num_ctx repeat_last_n
             repeat_penalty temperature seed num_predict top_k top_p min_p stop].each do |attr|
            define_method(attr) do
              options&.dig(attr)
            end

            define_method(:"#{attr}=") do |value|
              @ollama_params[:options] ||= {}
              @ollama_params[:options][attr] = value
            end
          end

          private

          # @api private
          # @param params [Hash]
          # @return [Hash]
          def apply_defaults(params)
            # Apply defaults
            DEFAULTS.each do |key, value|
              params[key] = value unless params.key?(key)
            end

            params
          end
        end
      end
    end
  end
end
