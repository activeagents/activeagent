# frozen_string_literal: true

require "active_agent/providers/common/model"
require "active_agent/providers/common/usage"

module ActiveAgent
  module Providers
    module Common
      module Responses
        # Provides unified interface for AI provider responses across OpenAI, Anthropic, etc.
        #
        # @abstract Subclass and override {#usage} if provider uses non-standard format
        #
        # @note Use specialized subclasses for specific response types:
        #   - {Prompt} for conversational/completion responses
        #   - {Embed} for embedding responses
        #
        # @example Accessing response data
        #   response = agent.prompt.generate_now
        #   response.success?         #=> true
        #   response.usage            #=> Usage object with normalized fields
        #   response.total_tokens     #=> 30
        #
        # @example Inspecting raw provider data
        #   response.raw_request      #=> { "model" => "gpt-4", "messages" => [...] }
        #   response.raw_response     #=> { "id" => "chatcmpl-...", "choices" => [...] }
        #
        # @see Prompt
        # @see Embed
        # @see BaseModel
        class Base < BaseModel
          # @!attribute [r] context
          #   Original request context sent to the provider.
          #
          #   Includes instructions, messages, tools, and configuration.
          #
          #   @return [Hash]
          attribute :context, writable: false

          # @!attribute [r] raw_request
          #   Most recent request in provider-specific format.
          #
          #   Useful for debugging and logging.
          #
          #   @return [Hash]
          attribute :raw_request, writable: false

          # @!attribute [r] raw_response
          #   Most recent response in provider-specific format.
          #
          #   Includes metadata, usage stats, and provider-specific fields.
          #   Hash keys are deep symbolized for consistent access.
          #
          #   @return [Hash]
          attribute :raw_response, writable: false

          # @!attribute [r] usages
          #   Usage objects from each API call in multi-turn conversations.
          #
          #   Each call (e.g., for tool calling) tracks usage separately. These are
          #   summed to provide cumulative statistics via {#usage}.
          #
          #   @return [Array<Usage>]
          attribute :usages, default: -> { [] }, writable: false

          # Initializes response with deep-duplicated attributes.
          #
          # Deep duplication prevents external modifications from affecting internal state.
          # The raw_response is deep symbolized for consistent key access across providers.
          #
          # @param kwargs [Hash]
          # @option kwargs [Hash] :context
          # @option kwargs [Hash] :raw_request
          # @option kwargs [Hash] :raw_response
          def initialize(kwargs = {})
            kwargs = kwargs.deep_dup # Ensure that userland can't fuck with our memory space

            # Deep symbolize raw_response for consistent access across all extraction methods
            if kwargs[:raw_response].is_a?(Hash)
              kwargs[:raw_response] = kwargs[:raw_response].deep_symbolize_keys
            end

            super(kwargs)
          end

          # @return [String, Array<Hash>, nil]
          def instructions
            context[:instructions]
          end

          # @todo Better handling of failure flows
          # @return [Boolean]
          def success?
            true
          end

          # Normalized usage statistics across all providers.
          #
          # For multi-turn conversations with tool calling, returns cumulative
          # usage across all API calls (sum of {#usages}).
          #
          # @return [Usage, nil]
          #
          # @example Single-turn usage
          #   response.usage.input_tokens      #=> 100
          #   response.usage.output_tokens     #=> 25
          #   response.usage.total_tokens      #=> 125
          #
          # @example Multi-turn usage (cumulative)
          #   # After 3 API calls due to tool usage:
          #   response.usage.input_tokens      #=> 350 (sum of all calls)
          #   response.usage.output_tokens     #=> 120 (sum of all calls)
          #
          # @see Usage
          def usage
            @usage ||= begin
              if usages.any?
                usages.reduce(:+)
              elsif raw_response
                Usage.from_provider_usage(
                  raw_response.is_a?(Hash) ? raw_response[:usage] : raw_response.usage
                )
              end
            end
          end

          # Response ID from provider, useful for tracking and debugging.
          #
          # @return [String, nil]
          #
          # @example
          #   response.id  #=> "chatcmpl-CbDx1nXoNSBrNIMhiuy5fk7jXQjmT" (OpenAI)
          #   response.id  #=> "msg_01RotDmSnYpKQjrTpaHUaEBz" (Anthropic)
          #   response.id  #=> "gen-1761505659-yxgaVsqVABMQqw6oA7QF" (OpenRouter)
          def id
            @id ||= begin
              return nil unless raw_response

              if raw_response.is_a?(Hash)
                raw_response[:id]
              elsif raw_response.respond_to?(:id)
                raw_response.id
              end
            end
          end

          # Model name from provider response.
          #
          # Useful for confirming which model was actually used, as providers may
          # use different versions than requested.
          #
          # @return [String, nil]
          #
          # @example
          #   response.model  #=> "gpt-4o-mini-2024-07-18"
          #   response.model  #=> "claude-3-5-haiku-20241022"
          def model
            @model ||= begin
              return nil unless raw_response

              if raw_response.is_a?(Hash)
                raw_response[:model]
              elsif raw_response.respond_to?(:model)
                raw_response.model
              end
            end
          end

          # Finish reason from provider response.
          #
          # Indicates why generation stopped (e.g., "stop", "length", "tool_calls").
          # Normalizes access across providers that use different field names.
          #
          # @return [String, nil]
          #
          # @example
          #   response.finish_reason  #=> "stop"
          #   response.finish_reason  #=> "length"
          #   response.finish_reason  #=> "tool_calls"
          #   response.stop_reason    #=> "stop" (alias)
          def finish_reason
            @finish_reason ||= begin
              return nil unless raw_response

              if raw_response.is_a?(Hash)
                # OpenAI format: choices[0].finish_reason or choices[0].message.finish_reason
                raw_response.dig(:choices, 0, :finish_reason) ||
                  raw_response.dig(:choices, 0, :message, :finish_reason) ||
                  # Anthropic format: stop_reason
                  raw_response[:stop_reason]
              end
            end
          end
          alias_method :stop_reason, :finish_reason
        end
      end
    end
  end
end
