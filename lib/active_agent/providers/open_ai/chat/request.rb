# frozen_string_literal: true

require "delegate"
require "json"
require_relative "transforms"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        # Wraps OpenAI gem's CompletionCreateParams with normalization
        #
        # Delegates to OpenAI::Models::Chat::CompletionCreateParams while providing
        # parameter normalization and shorthand format support via the Transforms module.
        #
        # All OpenAI Chat API fields are available via delegation:
        # model, messages, temperature, max_tokens, max_completion_tokens, top_p,
        # frequency_penalty, presence_penalty, tools, tool_choice, response_format,
        # stream_options, audio, prediction, metadata, modalities, service_tier, store,
        # parallel_tool_calls, reasoning_effort, verbosity, stop, seed, logit_bias,
        # logprobs, top_logprobs, prompt_cache_key, safety_identifier, user,
        # web_search_options, function_call, functions
        #
        # @example Basic usage
        #   request = Request.new(
        #     model: "gpt-4o",
        #     messages: [{role: "user", content: "Hello"}]
        #   )
        #
        # @example String message normalization
        #   Request.new(model: "gpt-4o", messages: "Hello")
        #   # Normalized to: [{role: "user", content: "Hello"}]
        #
        # @example Instructions support
        #   Request.new(
        #     model: "gpt-4o",
        #     messages: [{role: "user", content: "Hi"}],
        #     instructions: ["You are helpful", "Be concise"]
        #   )
        #   # instructions converted to developer messages and prepended
        class Request < SimpleDelegator
          # Default parameter values applied during initialization
          DEFAULTS = {
            frequency_penalty: 0,
            logprobs: false,
            modalities: [ "text" ],
            n: 1,
            parallel_tool_calls: true,
            presence_penalty: 0,
            service_tier: "auto",
            store: false,
            stream: false,
            temperature: 1,
            top_p: 1
          }.freeze

          # @return [Boolean, nil]
          attr_reader :stream

          # Creates a new chat completion request
          #
          # @param params [Hash] request parameters
          # @option params [String] :model required model identifier
          # @option params [Array, String, Hash] :messages required conversation messages
          # @option params [Array<String>, String] :instructions system/developer prompts
          # @option params [Hash, String, Symbol] :response_format
          # @option params [Float] :temperature (1) sampling temperature 0-2
          # @option params [Integer] :max_tokens maximum tokens to generate
          # @option params [Array] :tools available tool definitions
          # @raise [ArgumentError] when parameters are invalid
          def initialize(**params)
            # Step 1: Extract stream flag
            @stream = params[:stream]

            # Step 2: Apply defaults
            params = apply_defaults(params)

            # Step 3: Normalize all parameters (instructions, messages, response_format)
            params = Chat::Transforms.normalize_params(params)

            # Step 4: Create gem model - this validates all parameters!
            gem_model = ::OpenAI::Models::Chat::CompletionCreateParams.new(**params)

            # Step 5: Delegate all method calls to gem model
            super(gem_model)
          rescue ArgumentError => e
            # Re-raise with more context
            raise ArgumentError, "Invalid OpenAI Chat request parameters: #{e.message}"
          end

          # Serializes request for API call
          #
          # Uses gem's JSON serialization, removes default values for minimal
          # request body, and simplifies messages where possible.
          #
          # @return [Hash] cleaned request hash
          def serialize
            # Use gem's JSON serialization (handles all nested objects)
            hash = Chat::Transforms.gem_to_hash(__getobj__)

            # Cleanup and simplify for API request
            Chat::Transforms.cleanup_serialized_request(hash, DEFAULTS, __getobj__)
          end

          # @return [Array<Hash>, nil]
          def messages
            __getobj__.instance_variable_get(:@data)[:messages]
          end

          # Sets messages with normalization
          #
          # @param value [Array, String, Hash]
          # @return [void]
          def messages=(value)
            normalized_value = Chat::Transforms.normalize_messages(value)
            __getobj__.instance_variable_get(:@data)[:messages] = normalized_value
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
          # Prepends developer messages to the messages array for common format compatibility.
          #
          # @param values [Array<String>, String]
          # @return [void]
          def instructions=(*values)
            instructions_messages = Chat::Transforms.normalize_instructions(values.flatten)
            current_messages = messages || []
            self.messages = instructions_messages + current_messages
          end

          private

          # @api private
          # @param params [Hash]
          # @return [Hash]
          def apply_defaults(params)
            # Only apply defaults for keys that aren't present
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
