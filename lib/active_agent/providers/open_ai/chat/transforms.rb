# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        # Provides transformation methods for normalizing chat parameters
        # to OpenAI gem's native format
        #
        # Handles message normalization, shorthand formats, instructions mapping,
        # and response format conversion for the Chat Completions API.
        module Transforms
          class << self
            # Converts gem model object to hash via JSON round-trip
            #
            # @param gem_object [Object]
            # @return [Hash] with symbolized keys
            def gem_to_hash(gem_object)
              JSON.parse(gem_object.to_json, symbolize_names: true)
            end

            # Normalizes all request parameters for OpenAI Chat API
            #
            # Handles instructions mapping to developer messages, message normalization,
            # tools normalization, and response_format conversion. This is the main entry point
            # for parameter transformation.
            #
            # @param params [Hash]
            # @return [Hash] normalized parameters
            def normalize_params(params)
              params = params.dup

              # Map common format 'instructions' to developer messages
              if params.key?(:instructions)
                instructions_messages = normalize_instructions(params.delete(:instructions))
                params[:messages] = instructions_messages + Array(params[:messages] || [])
              end

              # Normalize messages for gem compatibility
              params[:messages] = normalize_messages(params[:messages]) if params[:messages]

              # Normalize tools from common format to Chat API format
              params[:tools] = normalize_tools(params[:tools]) if params[:tools]

              # Normalize tool_choice from common format
              params[:tool_choice] = normalize_tool_choice(params[:tool_choice]) if params[:tool_choice]

              # Normalize response_format if present
              params[:response_format] = normalize_response_format(params[:response_format]) if params[:response_format]

              params
            end

            # Normalizes messages to OpenAI Chat API format using gem message classes
            #
            # Handles various input formats:
            # - `"text"` → UserMessageParam
            # - `[{role: "user", content: "..."}]` → array of message params
            # - Merges consecutive same-role messages into single message
            #
            # @param messages [Array, String, Hash, nil]
            # @return [Array<OpenAI::Models::Chat::ChatCompletionMessageParam>, nil]
            def normalize_messages(messages)
              case messages
              when String
                [ create_message_param("user", messages) ]
              when Hash
                [ normalize_message(messages) ]
              when Array
                grouped = []

                messages.each do |msg|
                  normalized = normalize_message(msg)

                  # Don't merge tool messages - each needs its own tool_call_id
                  if grouped.empty? || grouped.last.role != normalized.role || normalized.role.to_s == "tool"
                    grouped << normalized
                  else
                    # Merge consecutive same-role messages
                    merged_content = merge_content(grouped.last.content, normalized.content)
                    grouped[-1] = create_message_param(grouped.last.role, merged_content)
                  end
                end

                grouped
              when nil
                nil
              else
                raise ArgumentError, "Cannot normalize #{messages.class} to messages array"
              end
            end

            # Normalizes a single message to proper gem message param class
            #
            # Handles shorthand formats:
            # - `"text"` → user message
            # - `{text: "..."}` → user message
            # - `{role: "system", text: "..."}` → system message
            # - `{image: "url"}` → user message with image content part
            # - `{text: "...", image: "url"}` → user message with text and image parts
            #
            # @param message [String, Hash, OpenAI::Models::Chat::ChatCompletionMessageParam]
            # @return [OpenAI::Models::Chat::ChatCompletionMessageParam]
            def normalize_message(message)
              case message
              when String
                create_message_param("user", message)
              when ::OpenAI::Models::Chat::ChatCompletionMessageParam
                # Already a gem message param - pass through
                message
              when Hash
                msg_hash = message.deep_symbolize_keys
                role = msg_hash[:role]&.to_s || "user"

                # Handle shorthand formats
                content = if msg_hash.key?(:content)
                  # Standard format with explicit content
                  msg_hash[:content]
                elsif msg_hash.key?(:text) && msg_hash.key?(:image)
                  # Shorthand with both text and image: { text: "...", image: "url" }
                  [
                    { type: "text", text: msg_hash[:text] },
                    { type: "image_url", image_url: { url: msg_hash[:image] } }
                  ]
                elsif msg_hash.key?(:image)
                  # Shorthand with only image: { image: "url" }
                  # Text comes from adjacent prompt arguments
                  [ { type: "image_url", image_url: { url: msg_hash[:image] } } ]
                elsif msg_hash.key?(:text)
                  # Shorthand: { text: "..." } or { role: "...", text: "..." }
                  msg_hash[:text]
                else
                  # No content specified
                  nil
                end

                # Create appropriate message param based on role and content
                extra_params = msg_hash.except(:role, :content, :text, :image)
                create_message_param(role, content, extra_params)
              else
                raise ArgumentError, "Cannot normalize #{message.class} to message"
              end
            end

            # Creates the appropriate gem message param class for the given role
            #
            # @param role [String] message role (developer, system, user, assistant, tool, function)
            # @param content [String, Array, Hash, nil]
            # @param extra_params [Hash] additional parameters (tool_call_id, name, etc.)
            # @return [OpenAI::Models::Chat::ChatCompletionMessageParam]
            # @raise [ArgumentError] when role is unknown
            def create_message_param(role, content, extra_params = {})
              params = { role: role }
              params[:content] = normalize_content(content) if content
              params.merge!(extra_params)

              case role.to_s
              when "developer"
                ::OpenAI::Models::Chat::ChatCompletionDeveloperMessageParam.new(**params)
              when "system"
                ::OpenAI::Models::Chat::ChatCompletionSystemMessageParam.new(**params)
              when "user"
                ::OpenAI::Models::Chat::ChatCompletionUserMessageParam.new(**params)
              when "assistant"
                ::OpenAI::Models::Chat::ChatCompletionAssistantMessageParam.new(**params)
              when "tool"
                ::OpenAI::Models::Chat::ChatCompletionToolMessageParam.new(**params)
              when "function"
                ::OpenAI::Models::Chat::ChatCompletionFunctionMessageParam.new(**params)
              else
                raise ArgumentError, "Unknown message role: #{role}"
              end
            end

            # Normalizes message content to Chat API format
            #
            # @param content [String, Array, Hash, nil]
            # @return [String, Array, nil]
            # @raise [ArgumentError] when content type is invalid
            def normalize_content(content)
              case content
              when String
                content
              when Array
                content.map { |part| normalize_content_part(part) }
              when Hash
                # Single content part as hash - wrap in array
                [ normalize_content_part(content) ]
              when nil
                nil
              else
                raise ArgumentError, "Cannot normalize #{content.class} to content"
              end
            end

            # Normalizes a single content part
            #
            # Converts strings to proper content part format with type and text keys.
            #
            # @param part [Hash, String]
            # @return [Hash] content part with symbolized keys
            # @raise [ArgumentError] when part type is invalid
            def normalize_content_part(part)
              case part
              when Hash
                part.deep_symbolize_keys
              when String
                { type: "text", text: part }
              else
                raise ArgumentError, "Cannot normalize #{part.class} to content part"
              end
            end

            # Merges two content values for consecutive same-role messages
            #
            # Preserves multiple text parts and mixed content as array structure
            # rather than concatenating strings.
            #
            # @param content1 [String, Array, nil]
            # @param content2 [String, Array, nil]
            # @return [Array] merged content parts
            def merge_content(content1, content2)
              # Convert to arrays for consistent handling
              arr1 = content_to_array(content1)
              arr2 = content_to_array(content2)

              merged = arr1 + arr2

              # Keep as array of content parts - don't simplify to string
              # This preserves multiple text parts and mixed content
              merged
            end

            # Converts content to array format for merging
            #
            # @param content [String, Array, nil]
            # @return [Array<Hash>] content parts with type and text keys
            def content_to_array(content)
              case content
              when String
                [ { type: "text", text: content } ]
              when Array
                content.map { |part| part.is_a?(String) ? { type: "text", text: part } : part }
              when nil
                []
              else
                [ content ]
              end
            end

            # Simplifies messages for cleaner API requests
            #
            # Converts gem message objects to hashes and simplifies content:
            # - Single text content arrays → strings
            # - Empty content arrays → removed
            #
            # @param messages [Array]
            # @return [Array<Hash>]
            def simplify_messages(messages)
              return messages unless messages.is_a?(Array)

              messages.map do |msg|
                # Convert to hash if it's a gem object
                simplified = msg.is_a?(Hash) ? msg.dup : gem_to_hash(msg)

                # Simplify content if it's a single text part
                if simplified[:content].is_a?(Array) && simplified[:content].size == 1
                  part = simplified[:content][0]
                  if part.is_a?(Hash) && part[:type] == "text" && part.keys.sort == [ :text, :type ]
                    simplified[:content] = part[:text]
                  end
                end

                # Remove empty content arrays
                simplified.delete(:content) if simplified[:content] == []

                simplified
              end
            end

            # Normalizes response_format to OpenAI Chat API format
            #
            # @param format [Hash, Symbol, String]
            # @return [Hash] normalized response format
            def normalize_response_format(format)
              case format
              when Hash
                format_hash = format.deep_symbolize_keys

                if format_hash[:type] == "json_schema" || format_hash[:type] == :json_schema
                  # json_schema format
                  {
                    type: "json_schema",
                    json_schema: {
                      name: format_hash[:name] || format_hash[:json_schema]&.dig(:name),
                      schema: format_hash[:schema] || format_hash[:json_schema]&.dig(:schema),
                      strict: format_hash[:strict] || format_hash[:json_schema]&.dig(:strict)
                    }.compact
                  }
                elsif format_hash[:type]
                  # Other type formats (json_object, text, etc.)
                  { type: format_hash[:type].to_s }
                else
                  # Pass through (already properly structured or complex)
                  format_hash
                end
              when Symbol, String
                # Simple string type
                { type: format.to_s }
              else
                format
              end
            end

            # Normalizes tools from common format to OpenAI Chat API format.
            #
            # Accepts tools in multiple formats:
            # - Common format: `{name: "...", description: "...", parameters: {...}}`
            # - Common format alt: `{name: "...", description: "...", input_schema: {...}}`
            # - Nested format: `{type: "function", function: {name: "...", parameters: {...}}}`
            #
            # Always outputs nested Chat API format: `{type: "function", function: {...}}`
            #
            # @param tools [Array<Hash>]
            # @return [Array<Hash>]
            def normalize_tools(tools)
              return tools unless tools.is_a?(Array)

              tools.map do |tool|
                tool_hash = tool.is_a?(Hash) ? tool.deep_symbolize_keys : tool

                # Already in nested format - return as is
                if tool_hash[:type] == "function" && tool_hash[:function]
                  tool_hash
                # Common format - convert to nested format
                elsif tool_hash[:name]
                  {
                    type: "function",
                    function: {
                      name: tool_hash[:name],
                      description: tool_hash[:description],
                      parameters: tool_hash[:parameters] || tool_hash[:input_schema]
                    }.compact
                  }
                else
                  tool_hash
                end
              end
            end

            # Normalizes tool_choice from common format to OpenAI Chat API format.
            #
            # Accepts:
            # - "auto" (common) → "auto" (passthrough)
            # - "required" (common) → "required" (passthrough)
            # - `{name: "..."}` (common) → `{type: "function", function: {name: "..."}}`
            # - Already nested format → passthrough
            #
            # @param tool_choice [String, Hash, Symbol]
            # @return [String, Hash, Symbol]
            def normalize_tool_choice(tool_choice)
              case tool_choice
              when "auto", :auto, "required", :required
                # Passthrough - Chat API accepts these directly
                tool_choice.to_s
              when Hash
                tool_choice_hash = tool_choice.deep_symbolize_keys

                # Already in nested format with type and function keys
                if tool_choice_hash[:type] == "function" && tool_choice_hash[:function]
                  tool_choice_hash
                # Common format with just name - convert to nested format
                elsif tool_choice_hash[:name]
                  {
                    type: "function",
                    function: {
                      name: tool_choice_hash[:name]
                    }
                  }
                else
                  tool_choice_hash
                end
              else
                tool_choice
              end
            end

            # Normalizes instructions to developer message format
            #
            # Converts instructions into developer messages with proper content structure.
            # Multiple instructions become content parts in a single developer message
            # rather than separate messages.
            #
            # @param instructions [Array<String>, String]
            # @return [Array<Hash>] developer messages
            def normalize_instructions(instructions)
              instructions_array = Array(instructions)

              # Convert multiple instructions into content parts for a single developer message
              if instructions_array.size > 1
                content_parts = instructions_array.map do |instruction|
                  { type: "text", text: instruction }
                end
                [ { role: "developer", content: content_parts } ]
              else
                instructions_array.map do |instruction|
                  { role: "developer", content: instruction }
                end
              end
            end

            # Cleans up serialized hash for API request
            #
            # Removes default values, simplifies messages, and handles special cases
            # like web_search_options (which requires empty hash to enable).
            #
            # @param hash [Hash] serialized request hash
            # @param defaults [Hash] default values to remove
            # @param gem_object [Object] original gem object for checking values
            # @return [Hash] cleaned request hash
            def cleanup_serialized_request(hash, defaults, gem_object)
              # Remove default values that shouldn't be in the request body
              defaults.each do |key, value|
                hash.delete(key) if hash[key] == value
              end

              # Simplify messages for cleaner API requests
              hash[:messages] = simplify_messages(hash[:messages]) if hash[:messages]

              # Add web_search_options if present (defaults to empty hash to enable feature)
              if gem_object.instance_variable_get(:@data)[:web_search_options]
                hash[:web_search_options] ||= {}
              end

              hash
            end
          end
        end
      end
    end
  end
end
