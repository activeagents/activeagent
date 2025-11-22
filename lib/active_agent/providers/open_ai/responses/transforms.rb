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

            # Normalizes tools from common format to OpenAI Responses API format.
            #
            # Accepts tools in multiple formats:
            # - Common format: `{name: "...", description: "...", parameters: {...}}`
            # - Nested format: `{type: "function", function: {name: "...", ...}}`
            # - Responses format: `{type: "function", name: "...", parameters: {...}}`
            #
            # Always outputs flat Responses API format.
            #
            # @param tools [Array<Hash>]
            # @return [Array<Hash>]
            def normalize_tools(tools)
              return tools unless tools.is_a?(Array)

              tools.map do |tool|
                tool_hash = tool.is_a?(Hash) ? tool.deep_symbolize_keys : tool

                # If already in Responses format (flat with type, name, parameters), return as-is
                if tool_hash[:type] == "function" && tool_hash[:name]
                  next tool_hash
                end

                # If in nested Chat API format, flatten it
                if tool_hash[:type] == "function" && tool_hash[:function]
                  func = tool_hash[:function]
                  next {
                    type: "function",
                    name: func[:name],
                    description: func[:description],
                    parameters: func[:parameters] || func[:input_schema]
                  }.compact
                end

                # If in common format (no type field), convert to Responses format
                if tool_hash[:name] && !tool_hash[:type]
                  next {
                    type: "function",
                    name: tool_hash[:name],
                    description: tool_hash[:description],
                    parameters: tool_hash[:parameters] || tool_hash[:input_schema]
                  }.compact
                end

                # Pass through other formats
                tool_hash
              end
            end

            # Normalizes MCP servers from common format to OpenAI Responses API format.
            #
            # Common format:
            #   {name: "stripe", url: "https://...", authorization: "token"}
            # OpenAI format:
            #   {type: "mcp", server_label: "stripe", server_url: "https://...", authorization: "token"}
            #
            # @param mcp_servers [Array<Hash>]
            # @return [Array<Hash>]
            def normalize_mcp_servers(mcp_servers)
              return mcp_servers unless mcp_servers.is_a?(Array)

              mcp_servers.map do |server|
                server_hash = server.is_a?(Hash) ? server.deep_symbolize_keys : server

                # If already in OpenAI format (has type: "mcp" and server_label), return as-is
                if server_hash[:type] == "mcp" && server_hash[:server_label]
                  next server_hash
                end

                # Convert common format to OpenAI format
                result = {
                  type: "mcp",
                  server_label: server_hash[:name] || server_hash[:server_label],
                  server_url: server_hash[:url] || server_hash[:server_url]
                }

                # Keep authorization field (OpenAI uses 'authorization', not 'authorization_token')
                if server_hash[:authorization]
                  result[:authorization] = server_hash[:authorization]
                end

                result.compact
              end
            end

            # Normalizes tool_choice from common format to OpenAI Responses API format.
            #
            # Responses API uses flat format for specific tool choice, unlike Chat API's nested format.
            # Must return gem model objects for proper serialization.
            #
            # Maps:
            # - "required" → :required symbol (force tool use)
            # - "auto" → :auto symbol (let model decide)
            # - { name: "..." } → ToolChoiceFunction model object
            #
            # @param tool_choice [String, Hash, Object]
            # @return [Symbol, Object] Symbol or gem model object
            def normalize_tool_choice(tool_choice)
              # If already a gem model object, return as-is
              return tool_choice if tool_choice.is_a?(::OpenAI::Models::Responses::ToolChoiceFunction) ||
                                     tool_choice.is_a?(::OpenAI::Models::Responses::ToolChoiceAllowed) ||
                                     tool_choice.is_a?(::OpenAI::Models::Responses::ToolChoiceTypes) ||
                                     tool_choice.is_a?(::OpenAI::Models::Responses::ToolChoiceMcp) ||
                                     tool_choice.is_a?(::OpenAI::Models::Responses::ToolChoiceCustom)

              case tool_choice
              when "required"
                :required  # Return as symbol
              when "auto"
                :auto  # Return as symbol
              when "none"
                :none  # Return as symbol
              when Hash
                choice_hash = tool_choice.deep_symbolize_keys

                # If already in proper format with type, try to create gem model
                if choice_hash[:type] == "function" && choice_hash[:name]
                  # Create ToolChoiceFunction gem model object
                  ::OpenAI::Models::Responses::ToolChoiceFunction.new(
                    type: :function,
                    name: choice_hash[:name]
                  )
                # Convert { name: "..." } to ToolChoiceFunction model
                elsif choice_hash[:name] && !choice_hash[:type]
                  ::OpenAI::Models::Responses::ToolChoiceFunction.new(
                    type: :function,
                    name: choice_hash[:name]
                  )
                else
                  choice_hash
                end
              else
                tool_choice
              end
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
