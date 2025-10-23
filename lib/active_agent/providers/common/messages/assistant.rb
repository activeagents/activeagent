# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Messages
        # Assistant message - messages sent by the AI assistant
        class Assistant < Base
          attribute :role, :string, as: "assistant"
          attribute :content, :string # Text content
          attribute :name, :string # Optional name for the assistant

          validates :content, presence: true

          # Extracts and parses JSON object or array from message content.
          #
          # Searches for the first occurrence of `{` or `[` and last occurrence of `}` or `]`,
          # then parses the content between them. Useful for extracting structured data from
          # user messages that may contain additional text.
          #
          # @param [Boolean] symbolize_names whether to symbolize hash keys
          # @param [Symbol, nil] normalize_names key normalization method (e.g., :underscore)
          # @return [Hash, Array, nil] parsed JSON structure or nil if parsing fails
          def json_object(symbolize_names: true, normalize_names: :underscore)
            start_char       = [ content.index("{"),  content.index("[") ].compact.min
            end_char         = [ content.rindex("}"), content.rindex("]") ].compact.max
            content_stripped = content[start_char..end_char] if start_char && end_char
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
        end
      end
    end
  end
end
