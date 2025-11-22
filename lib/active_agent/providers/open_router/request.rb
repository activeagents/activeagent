# frozen_string_literal: true

require "delegate"
require "json"
require_relative "transforms"
require_relative "requests/_types"

module ActiveAgent
  module Providers
    module OpenRouter
      # Wraps OpenAI gem's CompletionCreateParams with OpenRouter-specific extensions
      #
      # Delegates to OpenAI::Models::Chat::CompletionCreateParams for OpenAI-compatible
      # parameters while adding support for OpenRouter-specific features like plugins,
      # provider preferences, model fallbacks, and extended sampling parameters.
      #
      # OpenRouter-specific parameters:
      # - plugins: Array of plugin configurations (e.g., file-parser for PDFs)
      # - provider: ProviderPreferences object with require_parameters, data_collection, etc.
      # - transforms: Array of transformation strings
      # - models: Array of model strings for fallback routing
      # - route: Routing strategy (default: "fallback")
      # - top_k, min_p, top_a, repetition_penalty: Extended sampling parameters
      #
      # @example Basic usage
      #   request = Request.new(
      #     model: "openai/gpt-4",
      #     messages: [{role: "user", content: "Hello"}]
      #   )
      #
      # @example With OpenRouter-specific features
      #   request = Request.new(
      #     model: "openai/gpt-4",
      #     messages: [{role: "user", content: "Hello"}],
      #     models: ["anthropic/claude-3", "openai/gpt-4"],
      #     provider: {require_parameters: true}
      #   )
      class Request < SimpleDelegator
        # Default parameter values
        DEFAULTS = {
          frequency_penalty: 0,
          logprobs: false,
          n: 1,
          presence_penalty: 0,
          temperature: 1,
          top_p: 1,
          route: "fallback",
          models: [],
          transforms: []
        }.freeze

        # @return [Boolean, nil]
        attr_reader :stream

        # @return [Hash] OpenRouter-specific parameters
        attr_reader :openrouter_params

        # Creates a new OpenRouter request
        #
        # @param params [Hash] request parameters
        # @option params [String] :model model identifier (default: "openrouter/auto")
        # @option params [Array, String, Hash] :messages required conversation messages
        # @option params [Array] :plugins plugin configurations
        # @option params [Hash] :provider provider preferences
        # @option params [Array<String>] :transforms transformation strings
        # @option params [Array<String>] :models fallback model list
        # @option params [String] :route routing strategy
        # @option params [Integer] :top_k sampling parameter
        # @option params [Float] :min_p minimum probability sampling
        # @option params [Float] :top_a top-a sampling
        # @option params [Float] :repetition_penalty repetition penalty
        # @raise [ArgumentError] when parameters are invalid
        def initialize(**params)
          # Step 1: Extract stream flag
          @stream = params[:stream]

          # Step 2: Apply defaults
          params = apply_defaults(params)

          # Step 3: Normalize parameters and split into OpenAI vs OpenRouter-specific
          # This handles response_format special logic for structured output
          openai_params, @openrouter_params = Transforms.normalize_params(params)

          # Step 4: Create gem model with OpenAI-compatible params
          gem_model = ::OpenAI::Models::Chat::CompletionCreateParams.new(**openai_params)

          # Step 5: Delegate to the gem model
          super(gem_model)
        rescue ArgumentError => e
          raise ArgumentError, "Invalid OpenRouter request parameters: #{e.message}"
        end

        # Serializes request for API submission
        #
        # Merges OpenAI-compatible parameters with OpenRouter-specific extensions.
        #
        # @return [Hash] cleaned request hash
        def serialize
          # Get OpenAI params from gem model
          openai_hash = Transforms.gem_to_hash(__getobj__)

          # Merge with OpenRouter-specific params
          Transforms.cleanup_serialized_request(openai_hash, @openrouter_params, DEFAULTS, __getobj__)
        end

        # @return [Array<Hash>, nil]
        def messages
          __getobj__.instance_variable_get(:@data)[:messages]
        end

        # Sets messages with normalization
        #
        # Merges new messages with existing ones for compatibility.
        #
        # @param value [Array, String, Hash]
        # @return [void]
        def messages=(value)
          normalized_value = Transforms.normalize_messages(value)
          current_messages = messages || []

          # Merge behavior for OpenRouter compatibility
          merged = current_messages | Array(normalized_value)
          __getobj__.instance_variable_get(:@data)[:messages] = merged
        end

        # Alias for messages (common format compatibility)
        #
        # @return [Array<Hash>, nil]
        def message
          messages
        end

        # @param value [Array, String, Hash]
        # @return [void]
        def message=(value)
          self.messages = value
        end

        # Sets instructions as developer messages
        #
        # Prepends developer messages to the messages array.
        #
        # @param values [Array<String>, String]
        # @return [void]
        def instructions=(*values)
          instructions_messages = OpenAI::Chat::Transforms.normalize_instructions(values.flatten)
          current_messages = messages || []
          self.messages = instructions_messages + current_messages
        end

        # Gets tool_choice bypassing gem validation
        #
        # OpenRouter supports "any" which isn't valid in OpenAI gem types.
        #
        # @return [String, Hash, nil]
        def tool_choice
          __getobj__.instance_variable_get(:@data)[:tool_choice]
        end

        # Sets tool_choice bypassing gem validation
        #
        # OpenRouter supports "any" which isn't valid in OpenAI gem types,
        # so we bypass the gem's type validation by setting @data directly.
        #
        # @param value [String, Hash, nil]
        # @return [void]
        def tool_choice=(value)
          __getobj__.instance_variable_get(:@data)[:tool_choice] = value
        end

        # Accessor for OpenRouter-specific provider preferences
        #
        # @return [Hash, nil]
        def provider
          @openrouter_params[:provider]
        end

        # Sets provider preferences
        #
        # @param value [Hash]
        # @return [void]
        def provider=(value)
          @openrouter_params[:provider] = value
        end

        # Accessor for OpenRouter plugins
        #
        # @return [Array, nil]
        def plugins
          @openrouter_params[:plugins]
        end

        # Sets plugins
        #
        # @param value [Array]
        # @return [void]
        def plugins=(value)
          @openrouter_params[:plugins] = value
        end

        # Accessor for OpenRouter transforms
        #
        # @return [Array]
        def transforms
          @openrouter_params[:transforms] || []
        end

        # Sets transforms
        #
        # @param value [Array]
        # @return [void]
        def transforms=(value)
          @openrouter_params[:transforms] = value
        end

        # Accessor for fallback models
        #
        # @return [Array]
        def models
          @openrouter_params[:models] || []
        end

        # Sets fallback models
        #
        # @param value [Array]
        # @return [void]
        def models=(value)
          @openrouter_params[:models] = value
        end

        # Alias for backwards compatibility
        alias_method :fallback_models, :models
        alias_method :fallback_models=, :models=

        # Accessor for routing strategy
        #
        # @return [String]
        def route
          @openrouter_params[:route] || DEFAULTS[:route]
        end

        # Sets routing strategy
        #
        # @param value [String]
        # @return [void]
        def route=(value)
          @openrouter_params[:route] = value
        end

        private

        # @api private
        # @param params [Hash]
        # @return [Hash]
        def apply_defaults(params)
          # Set default model if not provided
          params[:model] ||= "openrouter/auto"

          # Apply other defaults
          DEFAULTS.each do |key, value|
            params[key] = value unless params.key?(key)
          end

          params
        end
      end
    end
  end
end
