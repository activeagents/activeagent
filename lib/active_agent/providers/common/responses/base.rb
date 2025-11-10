# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Common
      module Responses
        # Base response model for provider responses.
        #
        # This class represents the standard response structure from AI providers
        # across different services (OpenAI, Anthropic, etc.). It provides a unified
        # interface for accessing response data, usage statistics, and request context.
        #
        # @abstract Subclass and override {#usage} if provider uses non-standard format
        #
        # @note This is a base class. Use specialized subclasses for specific response types:
        #   - {Prompt} for conversational/completion responses with messages
        #   - {Embed} for embedding responses with vector data
        #
        # @example Accessing response data
        #   response = agent.prompt.generate_now
        #   response.success?         #=> true
        #   response.usage            #=> { "prompt_tokens" => 10, "completion_tokens" => 20 }
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
          #   The original context that was sent to the provider.
          #
          #   Contains structured information about the request including instructions,
          #   messages, tools, and other configuration passed to the LLM.
          #
          #   @return [Hash] the request context
          attribute :context, writable: false

          # @!attribute [r] raw_request
          #   The most recent request in provider-specific format.
          #
          #   Contains the actual API request payload sent to the provider,
          #   useful for debugging and logging.
          #
          #   @return [Hash] the provider-formatted request
          attribute :raw_request, writable: false

          # @!attribute [r] raw_response
          #   The most recent response in provider-specific format.
          #
          #   Contains the raw API response from the provider, including all
          #   metadata, usage stats, and provider-specific fields.
          #
          #   @return [Hash] the provider-formatted response
          attribute :raw_response, writable: false

          # Initializes a new response object with deep-duplicated attributes.
          #
          # Deep duplication ensures that the response object maintains its own
          # independent copy of the data, preventing external modifications from
          # affecting the response's internal state.
          #
          # @param kwargs [Hash] response attributes
          # @option kwargs [Hash] :context the original request context
          # @option kwargs [Hash] :raw_request the provider-formatted request
          # @option kwargs [Hash] :raw_response the provider-formatted response
          #
          # @return [Base] the initialized response object
          def initialize(kwargs = {})
            super(kwargs.deep_dup) # Ensure that userland can't fuck with our memory space
          end

          # Extracts instructions from the context.
          #
          # @return [String, Array<Hash>, nil] the instructions that were sent to the provider
          def instructions
            context[:instructions]
          end

          # Indicates whether the generation request was successful.
          #
          # @todo Better handling of failure flows
          #
          # @return [Boolean] true if successful, false otherwise
          def success?
            true
          end

          # Extracts usage statistics from the raw response.
          #
          # Most providers (OpenAI, Anthropic, etc.) return usage data in a
          # standardized format within the response. This method extracts that
          # information for token counting and billing purposes.
          #
          # @return [Hash, nil] usage statistics hash with keys like "prompt_tokens",
          #   "completion_tokens", and "total_tokens", or nil if not available
          #
          # @example Usage data structure
          #   {
          #     "prompt_tokens" => 10,
          #     "completion_tokens" => 20,
          #     "total_tokens" => 30
          #   }
          def usage
            return nil unless raw_response

            # Most providers store usage in the same format
            if raw_response.is_a?(Hash) && raw_response["usage"]
              raw_response["usage"]
            end
          end

          # Extracts the number of tokens used in the prompt/input.
          #
          # @return [Integer, nil] number of prompt tokens used, or nil if unavailable
          #
          # @example
          #   response.prompt_tokens #=> 10
          def prompt_tokens
            usage&.dig("prompt_tokens")
          end

          # Extracts the number of tokens used in the completion/output.
          #
          # @return [Integer, nil] number of completion tokens used, or nil if unavailable
          #
          # @example
          #   response.completion_tokens #=> 20
          def completion_tokens
            usage&.dig("completion_tokens")
          end

          # Extracts the total number of tokens used (prompt + completion).
          #
          # @return [Integer, nil] total number of tokens used, or nil if unavailable
          #
          # @example
          #   response.total_tokens #=> 30
          def total_tokens
            usage&.dig("total_tokens")
          end
        end
      end
    end
  end
end
