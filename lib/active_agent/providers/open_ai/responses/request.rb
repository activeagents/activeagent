# frozen_string_literal: true

require_relative "transforms"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        # Wraps OpenAI gem's ResponseCreateParams with field mapping and normalization
        #
        # Delegates to OpenAI::Models::Responses::ResponseCreateParams while providing
        # compatibility layer for common format fields and content normalization:
        # - `messages` → `input`
        # - `response_format` → `text` (via ResponseTextConfig)
        # - Instructions array joined to string
        class Request < SimpleDelegator
          # Default parameter values applied during initialization
          DEFAULTS = {
            service_tier: "auto",
            store: true,
            temperature: 1.0,
            top_p: 1.0,
            truncation: "disabled",
            parallel_tool_calls: true,
            background: false,
            include: []
          }.freeze

          # @return [Boolean, nil]
          attr_reader :stream

          # @return [Hash, nil]
          attr_reader :response_format

          # Creates a new response creation request
          #
          # Maps common format fields to Responses API format:
          # - `messages` → `input`
          # - `response_format` → `text` parameter
          # - Instructions array → joined string
          #
          # @param params [Hash] request parameters
          # @option params [String] :model required model identifier
          # @option params [Array, String, Hash] :input messages or content
          # @option params [Array, String, Hash] :messages alternative to :input (mapped automatically)
          # @option params [Hash, String, Symbol] :response_format
          # @option params [Array<String>, String] :instructions
          # @option params [Integer] :max_output_tokens
          # @raise [ArgumentError] when parameters are invalid
          def initialize(**params)
            # Step 1: Extract custom fields
            @stream = params[:stream]
            @response_format = params.delete(:response_format)

            # Step 2: Map common format 'messages' to OpenAI Responses 'input'
            if params.key?(:messages)
              params[:input] = params.delete(:messages)
            end

            # Step 3: Join instructions array into string (like Chat API)
            if params[:instructions].is_a?(Array)
              params[:instructions] = params[:instructions].join("\n")
            end

            # Step 4: Map response_format to text parameter for Responses API
            if @response_format
              params[:text] = Responses::Transforms.normalize_response_format(@response_format)
            end

            # Step 5: Apply defaults
            params = apply_defaults(params)

            # Step 6: Normalize input content for gem compatibility
            params[:input] = Responses::Transforms.normalize_input(params[:input]) if params[:input]

            # Step 7: Normalize tools and tool_choice from common format
            params[:tools] = Responses::Transforms.normalize_tools(params[:tools]) if params[:tools]
            params[:tool_choice] = Responses::Transforms.normalize_tool_choice(params[:tool_choice]) if params[:tool_choice]

            # Step 8: Normalize MCP servers from common format (mcps parameter)
            # OpenAI treats MCP servers as a special type of tool in the tools array
            mcp_param = params[:mcps] || params[:mcp_servers]
            if mcp_param&.any?
              normalized_mcp_tools = Responses::Transforms.normalize_mcp_servers(mcp_param)
              params.delete(:mcps)
              params.delete(:mcp_servers)
              # Merge MCP servers into tools array
              params[:tools] = (params[:tools] || []) + normalized_mcp_tools
            end

            # Step 9: Create gem model - delegates to OpenAI gem
            gem_model = ::OpenAI::Models::Responses::ResponseCreateParams.new(**params)

            # Step 10: Delegate all method calls to gem model
            super(gem_model)
          rescue ArgumentError => e
            # Re-raise with more context
            raise ArgumentError, "Invalid OpenAI Responses request parameters: #{e.message}"
          end

          # Serializes request for API call
          #
          # Uses gem's JSON serialization and delegates cleanup to Transforms module.
          #
          # @return [Hash] cleaned request hash
          def serialize
            hash = Responses::Transforms.gem_to_hash(__getobj__)
            Responses::Transforms.cleanup_serialized_request(hash, DEFAULTS, __getobj__)
          end

          # @return [Array, String, Hash, nil]
          def messages
            __getobj__.instance_variable_get(:@data)[:input]
          end

          # Sets input messages with normalization
          #
          # @param value [Array, String, Hash]
          # @return [void]
          def messages=(value)
            normalized_value = Responses::Transforms.normalize_input(value)
            __getobj__.instance_variable_get(:@data)[:input] = normalized_value
          end

          alias_method :message, :messages
          alias_method :message=, :messages=

          private

          # @api private
          # @param params [Hash]
          # @return [Hash]
          def apply_defaults(params)
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
