# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Messages
        # Represents messages sent by the AI assistant in a conversation.
        class Assistant < Base
          attribute :role, :string, as: "assistant"
          attribute :content # Accept both string and array (provider-native formats)
          attribute :name, :string

          validates :content, presence: true

          # Extracts and parses JSON object or array from message content.
          #
          # Searches for the first occurrence of `{` or `[` and last occurrence of `}` or `]`,
          # then parses the content between them. Useful for extracting structured data from
          # assistant messages that may contain additional text around the JSON.
          #
          # @param symbolize_names [Boolean] whether to symbolize hash keys
          # @param normalize_names [Symbol, nil] key normalization method (e.g., :underscore)
          # @return [Hash, Array, nil] parsed JSON structure or nil if parsing fails
          def parsed_json(symbolize_names: true, normalize_names: :underscore)
            # Handle array content (from content blocks) by searching through each block
            content_str = if content.is_a?(Array)
              content.map { |block| block.is_a?(Hash) ? block[:text] : block.to_s }.join("\n")
            else
              content.to_s
            end

            start_char       = [ content_str.index("{"),  content_str.index("[") ].compact.min
            end_char         = [ content_str.rindex("}"), content_str.rindex("]") ].compact.max
            content_stripped = content_str[start_char..end_char] if start_char && end_char
            return unless content_stripped

            content_parsed = JSON.parse(content_stripped)

            transform_hash = ->(hash) do
              next if hash.nil?

              hash = hash.deep_transform_keys(&normalize_names) if normalize_names
              hash = hash.deep_symbolize_keys if symbolize_names
              hash
            end

            case content_parsed
            when Hash  then transform_hash.call(content_parsed)
            when Array then content_parsed.map { |item| item.is_a?(Hash) ? transform_hash.call(item) : item }
            else content_parsed
            end
          rescue JSON::ParserError
            nil
          end

          # Returns content as a string, handling both string and array formats
          def text
            if content.is_a?(Array)
              content.map { |block| block.is_a?(Hash) ? block[:text] : block.to_s }.join("\n")
            else
              content.to_s
            end
          end

          alias_method :json_object, :parsed_json
          alias_method :parse_json,  :parsed_json
        end
      end
    end
  end
end
