# frozen_string_literal: true

require "delegate"
require "json"
require_relative "transforms"

module ActiveAgent
  module Providers
    module Anthropic
      # Request wrapper that delegates to Anthropic gem model.
      #
      # Uses SimpleDelegator to wrap ::Anthropic::Models::MessageCreateParams,
      # eliminating the need to maintain duplicate attribute definitions while
      # providing convenience transformations and custom fields.
      #
      # All standard Anthropic API fields are automatically available via delegation:
      # - model, messages, max_tokens
      # - system, temperature, top_k, top_p, stop_sequences
      # - tools, tool_choice, thinking
      # - stream, metadata, context_management, container, service_tier, mcp_servers
      #
      # Custom fields managed separately:
      # - response_format (simulated JSON mode feature)
      #
      # @example Basic usage
      #   request = Request.new(
      #     model: "claude-3-5-haiku-latest",
      #     messages: [{role: "user", content: "Hello"}]
      #   )
      #   request.model      #=> "claude-3-5-haiku-latest"
      #   request.max_tokens #=> 4096 (default)
      #
      # @example With transformations
      #   # String content is automatically normalized
      #   request = Request.new(
      #     model: "...",
      #     messages: [{role: "user", content: "Hi"}]
      #   )
      #   # Internally becomes: [{type: "text", text: "Hi"}]
      #
      # @example Custom field
      #   request = Request.new(
      #     model: "...",
      #     messages: [...],
      #     response_format: {type: "json_object"}
      #   )
      #   request.response_format #=> {type: "json_object"}
      class Request < SimpleDelegator
        # Default max_tokens value when not specified
        DEFAULT_MAX_TOKENS = 4096

        # Default values for optional parameters
        DEFAULTS = {
          max_tokens: DEFAULT_MAX_TOKENS,
          stop_sequences: [],
          mcp_servers: []
        }.freeze

        # @return [Hash, nil] simulated JSON response format configuration
        attr_reader :response_format

        # @return [Boolean, nil] whether to stream the response
        attr_reader :stream

        # @param params [Hash]
        # @option params [String] :model required
        # @option params [Array<Hash>] :messages required
        # @option params [Integer] :max_tokens (4096)
        # @option params [Hash] :response_format custom field for JSON mode simulation
        # @option params [String] :anthropic_beta beta version for features like MCP
        # @raise [ArgumentError] when gem model validation fails
        def initialize(**params)
          # Step 1: Extract custom fields that gem doesn't support
          @response_format = params.delete(:response_format)
          @stream = params.delete(:stream)
          anthropic_beta = params.delete(:anthropic_beta)

          # Step 2: Map common format 'instructions' to Anthropic's 'system'
          if params.key?(:instructions)
            params[:system] = params.delete(:instructions)
          end

          # Step 3: Apply defaults
          params = apply_defaults(params)

          # Step 4: Transform params for gem compatibility
          transformed = Transforms.normalize_params(params)

          # Step 5: Determine if we need beta params (for MCP or other beta features)
          use_beta = anthropic_beta.present? || transformed[:mcp_servers]&.any?

          # Step 6: Add betas parameter if using beta API
          if use_beta
            # Default to MCP beta version if not specified
            beta_version = anthropic_beta || "mcp-client-2025-04-04"
            transformed[:betas] = [ beta_version ]
          end

          # Step 7: Create gem model - use Beta version if needed
          gem_model = if use_beta
            ::Anthropic::Models::Beta::MessageCreateParams.new(**transformed)
          else
            ::Anthropic::Models::MessageCreateParams.new(**transformed)
          end

          # Step 8: Delegate all method calls to gem model
          super(gem_model)
        rescue ArgumentError => e
          # Re-raise with more context
          raise ArgumentError, "Invalid Anthropic request parameters: #{e.message}"
        end

        # Serializes request for API call.
        #
        # Uses gem's JSON serialization and delegates cleanup to Transforms module.
        #
        # @return [Hash]
        def serialize
          # Use gem's JSON serialization (handles all nested objects)
          hash = Anthropic::Transforms.gem_to_hash(__getobj__)

          # Delegate cleanup to transforms module
          Transforms.cleanup_serialized_request(hash, DEFAULTS, __getobj__)
        end

        # Accessor for system instructions.
        #
        # Must override SimpleDelegator's method_missing because Ruby's Kernel.system
        # conflicts with delegation. The gem stores data in @data instance variable.
        #
        # @return [String, Array, nil]
        def system
          __getobj__.instance_variable_get(:@data)[:system]
        end

        # @param value [String, Array]
        def system=(value)
          __getobj__.instance_variable_get(:@data)[:system] = value
        end

        # Alias for system (common format compatibility).
        #
        # @return [String, Array, nil]
        def instructions
          system
        end

        # @param value [String, Array]
        def instructions=(value)
          self.system = value
        end

        # Accessor for MCP servers.
        #
        # Safely returns MCP servers array, defaulting to empty array if not set.
        #
        # @return [Array]
        def mcp_servers
          __getobj__.instance_variable_get(:@data)[:mcp_servers] || []
        end

        # Removes the last message from the messages array.
        #
        # Used for JSON format simulation to remove the lead-in assistant message.
        #
        # @return [void]
        def pop_message!
          new_messages = messages.dup
          new_messages.pop
          self.messages = new_messages
        end

        private

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
