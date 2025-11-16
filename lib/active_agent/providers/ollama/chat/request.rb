# frozen_string_literal: true

require "delegate"
require "json"
require_relative "transforms"

module ActiveAgent
  module Providers
    module Ollama
      module Chat
        # Wraps OpenAI gem's CompletionCreateParams with Ollama-specific extensions
        #
        # Delegates to OpenAI::Models::Chat::CompletionCreateParams for OpenAI-compatible
        # parameters while adding support for Ollama-specific features like format,
        # options, keep_alive, and raw mode.
        #
        # Ollama-specific parameters:
        # - format: Return response in JSON or as a JSON schema (String "json" or Hash)
        # - options: Additional model parameters (Hash of key-value pairs)
        # - keep_alive: Controls how long model stays in memory (String duration or Integer seconds)
        # - raw: If true, no formatting applied to prompt (Boolean)
        #
        # @example Basic usage
        #   request = Request.new(
        #     model: "llama2",
        #     messages: [{role: "user", content: "Hello"}]
        #   )
        #
        # @example With Ollama-specific features
        #   request = Request.new(
        #     model: "llama2",
        #     messages: [{role: "user", content: "Hello"}],
        #     format: "json",
        #     options: {temperature: 0.7, num_predict: 100},
        #     keep_alive: "5m"
        #   )
        class Request < SimpleDelegator
          # Default parameter values
          DEFAULTS = {
            frequency_penalty: 0,
            logprobs: false,
            n: 1,
            parallel_tool_calls: true,
            presence_penalty: 0,
            temperature: 1,
            top_p: 1,
            raw: false,
            keep_alive: "5m"
          }.freeze

          # @return [Boolean, nil]
          attr_reader :stream

          # @return [Hash] Ollama-specific parameters
          attr_reader :ollama_params

          # Creates a new Ollama request
          #
          # @param params [Hash] request parameters
          # @option params [String] :model model identifier (required)
          # @option params [Array, String, Hash] :messages required conversation messages
          # @option params [String, Hash] :format JSON format ("json" or schema object)
          # @option params [Hash] :options model-specific options
          # @option params [String, Integer] :keep_alive memory duration
          # @option params [Boolean] :raw raw prompt mode
          # @raise [ArgumentError] when parameters are invalid
          def initialize(**params)
            # Step 1: Extract stream flag
            @stream = params[:stream]

            # Step 2: Apply defaults
            params = apply_defaults(params)

            # Step 3: Normalize parameters and split into OpenAI vs Ollama-specific
            openai_params, @ollama_params = Transforms.normalize_params(params)

            # Step 4: Validate Ollama-specific parameters
            validate_format(@ollama_params[:format]) if @ollama_params[:format]
            validate_options(@ollama_params[:options]) if @ollama_params[:options]

            # Step 5: Create gem model with OpenAI-compatible params
            gem_model = ::OpenAI::Models::Chat::CompletionCreateParams.new(**openai_params)

            # Step 6: Delegate to the gem model
            super(gem_model)
          rescue ArgumentError => e
            raise ArgumentError, "Invalid Ollama Chat request parameters: #{e.message}"
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
            Transforms.cleanup_serialized_request(openai_hash, @ollama_params, DEFAULTS, __getobj__)
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

            # Merge behavior for Ollama compatibility
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
            instructions_messages = Transforms.normalize_instructions(values.flatten)
            current_messages = messages || []
            self.messages = instructions_messages + current_messages
          end

          # Accessor for Ollama format parameter
          #
          # @return [String, Hash, nil]
          def format
            @ollama_params[:format]
          end

          # Sets format parameter
          #
          # @param value [String, Hash]
          # @return [void]
          def format=(value)
            validate_format(value)
            @ollama_params[:format] = value
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
            validate_options(value)
            @ollama_params[:options] = value
          end

          # Accessor for keep_alive parameter
          #
          # @return [String, Integer, nil]
          def keep_alive
            @ollama_params[:keep_alive] || DEFAULTS[:keep_alive]
          end

          # Sets keep_alive parameter
          #
          # @param value [String, Integer]
          # @return [void]
          def keep_alive=(value)
            @ollama_params[:keep_alive] = value
          end

          # Accessor for raw parameter
          #
          # @return [Boolean]
          def raw
            @ollama_params[:raw] || DEFAULTS[:raw]
          end

          # Sets raw parameter
          #
          # @param value [Boolean]
          # @return [void]
          def raw=(value)
            @ollama_params[:raw] = value
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

          # @api private
          # @param format [String, Hash, nil]
          # @raise [ArgumentError]
          def validate_format(format)
            return if format.nil?
            return if format == "json"
            return if format.is_a?(Hash) # JSON schema object

            raise ArgumentError, "format must be 'json' or a JSON schema object"
          end

          # @api private
          # @param options [Hash, nil]
          # @raise [ArgumentError]
          def validate_options(options)
            return if options.nil?

            unless options.is_a?(Hash)
              raise ArgumentError, "options must be a hash of model parameters"
            end
          end
        end
      end
    end
  end
end
