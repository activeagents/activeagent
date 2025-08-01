# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    class Response
      attr_reader :message, :prompt, :raw_response

      def initialize(prompt:, message: nil, raw_response: nil)
        @prompt = prompt
        @message = message || prompt.message
        @raw_response = raw_response
      end

      # Extract usage statistics from the raw response
      def usage
        return nil unless @raw_response

        # OpenAI/OpenRouter format
        if @raw_response.is_a?(Hash) && @raw_response["usage"]
          @raw_response["usage"]
        # Anthropic format
        elsif @raw_response.is_a?(Hash) && @raw_response["usage"]
          @raw_response["usage"]
        else
          nil
        end
      end

      # Helper methods for common usage stats
      def prompt_tokens
        usage&.dig("prompt_tokens")
      end

      def completion_tokens
        usage&.dig("completion_tokens")
      end

      def total_tokens
        usage&.dig("total_tokens")
      end
    end
  end
end
