# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    class Response
      attr_reader :message, :prompt, :raw_response, :raw_request
      attr_accessor :metadata

      def initialize(prompt:, message: nil, raw_response: nil, raw_request: nil, metadata: nil)
        @prompt = prompt
        @message = message || prompt.message
        @raw_response = raw_response
        @raw_request = sanitize_request(raw_request)
        @metadata = metadata || {}
      end

      # Extract usage statistics from the raw response
      def usage
        return nil unless @raw_response

        # Most providers store usage in the same format
        if @raw_response.is_a?(Hash) && @raw_response["usage"]
          @raw_response["usage"]
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

      private

      def sanitize_request(request)
        return nil if request.nil?
        return request unless request.is_a?(Hash)

        # Deep clone the request to avoid modifying the original
        sanitized = request.deep_dup

        # Sanitize any string values in the request
        sanitize_hash_values(sanitized)
      end

      def sanitize_hash_values(hash)
        hash.each do |key, value|
          case value
          when String
            # Use ActiveAgent's sanitize_credentials to replace sensitive data
            hash[key] = ActiveAgent.sanitize_credentials(value)
          when Hash
            sanitize_hash_values(value)
          when Array
            value.each_with_index do |item, index|
              if item.is_a?(String)
                value[index] = ActiveAgent.sanitize_credentials(item)
              elsif item.is_a?(Hash)
                sanitize_hash_values(item)
              end
            end
          end
        end
        hash
      end
    end
  end
end
