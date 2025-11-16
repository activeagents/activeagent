# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        # Provides transformation methods for normalizing response parameters
        # to OpenAI gem's native format
        #
        # Handles input normalization, message conversion, and response format
        # transformation for the Responses API.
        module Transforms
          class << self
            # Converts gem model object to hash via JSON round-trip
            #
            # @param gem_object [Object]
            # @return [Hash] with symbolized keys
            def gem_to_hash(gem_object)
              JSON.parse(gem_object.to_json, symbolize_names: true)
            end

            # Simplifies input for cleaner API requests
            #
            # Unwraps single-element arrays:
            # - `["text"]` → `"text"`
            # - `[{type: "input_text", text: "..."}]` → `"..."`
            # - `[{role: "user", content: "..."}]` → `"..."`
            #
            # @param input [Array, String, Hash]
            # @return [String, Array, Hash]
            def simplify_input(input)
              return input unless input.is_a?(Array)

              # Single string element - unwrap it
              if input.size == 1 && input[0].is_a?(String)
                return input[0]
              end

              # Single content object {type: "input_text", text: "..."} - unwrap to string
              if input.size == 1 &&
                 input[0].is_a?(Hash) &&
                 input[0][:type] == "input_text" &&
                 input[0][:text].is_a?(String) &&
                 input[0].keys.sort == [ :text, :type ]
                return input[0][:text]
              end

              # Single message with string content - simplify to string
              if input.size == 1 &&
                 input[0].is_a?(Hash) &&
                 input[0][:role] == "user" &&
                 input[0][:content].is_a?(String)
                return input[0][:content]
              end

              input
            end

            # Normalizes response_format to OpenAI Responses API text parameter
            #
            # Maps common response_format structures to Responses API format.
            # Returns ResponseTextConfig object to preserve proper nesting.
            #
            # @param format [Hash, Symbol, String]
            # @return [OpenAI::Models::Responses::ResponseTextConfig]
            def normalize_response_format(format)
              text_hash = case format
              when Hash
                if format[:type] == "json_schema" || format[:type] == :json_schema
                  # json_schema format: map to Responses API structure
                  {
                    format: {
                      type: "json_schema",
                      name: format[:name] || format[:json_schema]&.dig(:name),
                      schema: format[:schema] || format[:json_schema]&.dig(:schema),
                      strict: format[:strict] || format[:json_schema]&.dig(:strict)
                    }.compact
                  }
                elsif format[:type] == "json_object" || format[:type] == :json_object
                  # json_object format
                  { format: { type: "json_object" } }
                elsif format[:type]
                  # Other simple type formats (text, etc.) - wrap in format key
                  { format: { type: format[:type].to_s } }
                else
                  # Pass through other hash formats (already has format key or complex structure)
                  format
                end
              when Symbol, String
                # Simple format types
                { format: { type: format.to_s } }
              else
                format
              end

              # Convert hash to ResponseTextConfig object to preserve nesting
              ::OpenAI::Models::Responses::ResponseTextConfig.new(**text_hash)
            end

            # Normalizes input/messages to gem-compatible format
            #
            # Handles various input formats:
            # - `"text"` → string (passthrough)
            # - `{role: "user", content: "..."}` → wrapped in array
            # - `[{text: "..."}, {image: "url"}]` → wrapped as user message with content array
            # - `["msg1", "msg2"]` → array of user messages
            #
            # @param input [String, Hash, Array, Object]
            # @return [String, Array<Hash>]
            def normalize_input(input)
              # String inputs pass through unchanged
              return input if input.is_a?(String)

              # Single hash should be wrapped in an array
              if input.is_a?(Hash)
                return [ normalize_message(input) ]
              end

              # Handle arrays
              return input unless input.respond_to?(:map)

              # Check if this is an array of content items (strings or text/image/document hashes)
              # Content items don't have a :role key (messages do)
              # BUT NOT a single string (which should have been caught above)
              all_content_items = input.size > 1 && input.all? do |item|
                if item.is_a?(String)
                  true
                elsif item.is_a?(Hash)
                  # If it has a role, it's a message, not a content item
                  !item.key?(:role) && (item.key?(:text) || item.key?(:image) || item.key?(:document))
                else
                  false
                end
              end

              if all_content_items
                # These are multiple content items, wrap in a user message
                content = input.map { |item| normalize_message(item) }
                return [ { role: "user", content: content } ]
              end

              # Otherwise treat as array of messages
              input.map { |item| normalize_message(item, context: :input) }
            end

            # Normalizes a single message to hash format
            #
            # Handles shorthand formats:
            # - `{text: "..."}` → user message
            # - `{image: "url"}` → input_image content part
            # - `{document: "url"}` → input_file content part
            #
            # @param message [Hash, String, Object]
            # @param context [Symbol] :input for messages, :content for content parts
            # @return [Hash, String]
            def normalize_message(message, context: :content)
              # If it's our custom model object, serialize it
              if message.respond_to?(:serialize)
                message.serialize
              elsif message.is_a?(Hash)
                # If it has a role, it's a message - convert :text to :content
                if message.key?(:role)
                  normalized = message.dup
                  if normalized.key?(:text) && !normalized.key?(:content)
                    normalized[:content] = normalized.delete(:text)
                  end
                  return normalized
                end

                # Expand shorthand formats to full structures for content items
                if message.key?(:image)
                  { type: "input_image", image_url: message[:image] }
                elsif message.key?(:document)
                  document_value = message[:document]
                  if document_value.start_with?("data:")
                    { type: "input_file", filename: "document.pdf", file_data: document_value }
                  else
                    { type: "input_file", file_url: document_value }
                  end
                elsif message.key?(:text) && message.size == 1
                  # Single :text key without :role - treat as user message
                  { role: "user", content: message[:text] }
                elsif message.key?(:text)
                  # Bare text content item with other keys
                  { type: "input_text", text: message[:text] }
                else
                  message
                end
              elsif message.is_a?(String)
                # Context matters: in input array, strings become messages; in content array, they become input_text
                if context == :input
                  { role: "user", content: message }
                else
                  { type: "input_text", text: message }
                end
              else
                # Pass through anything else
                message
              end
            end

            # Cleans up serialized request for API submission
            #
            # Removes default values and simplifies input where possible.
            #
            # @param hash [Hash] serialized request
            # @param defaults [Hash] default values to remove
            # @param gem_object [Object] original gem object
            # @return [Hash] cleaned request hash
            def cleanup_serialized_request(hash, defaults, gem_object)
              # Remove default values that shouldn't be in the request body
              defaults.each do |key, value|
                hash.delete(key) if hash[key] == value
              end

              # Simplify input when possible for cleaner API requests
              hash[:input] = simplify_input(hash[:input]) if hash[:input]

              hash
            end
          end
        end
      end
    end
  end
end
