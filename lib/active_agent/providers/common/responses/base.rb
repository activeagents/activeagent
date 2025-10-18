# frozen_string_literal: true

require_relative "../_base_model"

module ActiveAgent
  module Providers
    module Common
      module Responses
        # Base response model for provider responses
        #
        # This class represents the standard response structure from AI providers.
        # It includes the original context, raw API data, and usage statistics.
        #
        # Use the specialized subclasses:
        # - PromptResponse for conversational/completion responses with messages
        # - EmbedResponse for embedding responses with data
        class Base < BaseModel
          # The original context that was sent (Hash)
          attribute :context, writable: false

          # The most recent request, in provider format (Hash)
          attribute :raw_request, writable: false

          # The most recent response, in provider format (Hash)
          attribute :raw_response, writable: false

          def initialize(kwargs = {})
            super(kwargs.deep_dup) # Ensure that userland can't fuck with our memory space
          end

          def instructions
            context[:instructions]
          end

          # Extract usage statistics from the raw response
          #
          # Most providers store usage data in the same format within the raw response.
          #
          # @return [Hash, nil] usage statistics hash or nil if not available
          def usage
            return nil unless raw_response

            # Most providers store usage in the same format
            if raw_response.is_a?(Hash) && raw_response["usage"]
              raw_response["usage"]
            end
          end

          # Helper method to extract prompt tokens from usage stats
          #
          # @return [Integer, nil] number of prompt tokens used
          def prompt_tokens
            usage&.dig("prompt_tokens")
          end

          # Helper method to extract completion tokens from usage stats
          #
          # @return [Integer, nil] number of completion tokens used
          def completion_tokens
            usage&.dig("completion_tokens")
          end

          # Helper method to extract total tokens from usage stats
          #
          # @return [Integer, nil] total number of tokens used
          def total_tokens
            usage&.dig("total_tokens")
          end
        end
      end
    end
  end
end
