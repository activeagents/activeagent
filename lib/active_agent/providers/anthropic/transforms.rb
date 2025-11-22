# frozen_string_literal: true

require "active_support/core_ext/hash/keys"

module ActiveAgent
  module Providers
    module Anthropic
      # Transforms between convenient input formats and Anthropic API structures.
      #
      # Provides bidirectional transformations:
      # - Expand: shortcuts → API format (string → content blocks, consecutive messages → grouped)
      # - Compress: API format → shortcuts (single content blocks → strings for efficiency)
      module Transforms
        class << self
          # Converts gem model object to hash via JSON round-trip.
          #
          # This ensures proper nested serialization and symbolic keys.
          #
          # @param gem_object [Object] any object responding to .to_json
          # @return [Hash]
          def gem_to_hash(gem_object)
            JSON.parse(gem_object.to_json, symbolize_names: true)
          end

          # @param params [Hash]
          # @return [Hash]
          def normalize_params(params)
            params = params.dup
            params[:messages] = normalize_messages(params[:messages]) if params[:messages]
            params[:system] = normalize_system(params[:system]) if params[:system]
            params[:tools] = normalize_tools(params[:tools]) if params[:tools]
            params[:tool_choice] = normalize_tool_choice(params[:tool_choice]) if params[:tool_choice]

            # Handle mcps parameter (common format) -> transforms to mcp_servers (provider format)
            if params[:mcps]
              params[:mcp_servers] = normalize_mcp_servers(params.delete(:mcps))
            elsif params[:mcp_servers]
              params[:mcp_servers] = normalize_mcp_servers(params[:mcp_servers])
            end

            params
          end

          # Normalizes tools from common format to Anthropic format.
          #
          # Accepts both `parameters` and `input_schema` keys, converting to Anthropic's `input_schema`.
          #
          # @param tools [Array<Hash>]
          # @return [Array<Hash>]
          def normalize_tools(tools)
            return tools unless tools.is_a?(Array)

            tools.map do |tool|
              tool_hash = tool.is_a?(Hash) ? tool.deep_symbolize_keys : tool

              # If already in Anthropic format (has input_schema), return as-is
              next tool_hash if tool_hash[:input_schema]

              # Convert common format with 'parameters' to Anthropic format with 'input_schema'
              if tool_hash[:parameters]
                tool_hash = tool_hash.dup
                tool_hash[:input_schema] = tool_hash.delete(:parameters)
              end

              tool_hash
            end
          end

          # Normalizes MCP servers from common format to Anthropic format.
          #
          # Common format:
          #   {name: "stripe", url: "https://...", authorization: "token"}
          # Anthropic format:
          #   {type: "url", name: "stripe", url: "https://...", authorization_token: "token"}
          #
          # @param mcp_servers [Array<Hash>]
          # @return [Array<Hash>]
          def normalize_mcp_servers(mcp_servers)
            return mcp_servers unless mcp_servers.is_a?(Array)

            mcp_servers.map do |server|
              server_hash = server.is_a?(Hash) ? server.deep_symbolize_keys : server

              # If already in Anthropic native format (has type: "url"), return as-is
              # Check for absence of common format 'authorization' field OR presence of native 'authorization_token'
              if server_hash[:type] == "url" && (server_hash[:authorization_token] || !server_hash[:authorization])
                next server_hash
              end

              # Convert common format to Anthropic format
              result = {
                type: "url",
                name: server_hash[:name],
                url: server_hash[:url]
              }

              # Map 'authorization' to 'authorization_token'
              if server_hash[:authorization]
                result[:authorization_token] = server_hash[:authorization]
              elsif server_hash[:authorization_token]
                result[:authorization_token] = server_hash[:authorization_token]
              end

              result.compact
            end
          end

          # Normalizes tool_choice from common format to Anthropic gem model objects.
          #
          # The Anthropic gem expects tool_choice to be a model object (ToolChoiceAuto,
          # ToolChoiceAny, ToolChoiceTool, etc.), not a plain hash.
          #
          # Maps:
          # - "required" → ToolChoiceAny (force tool use)
          # - "auto" → ToolChoiceAuto (let model decide)
          # - { name: "..." } → ToolChoiceTool with name
          #
          # @param tool_choice [String, Hash, Object]
          # @return [Object] Anthropic gem model object
          def normalize_tool_choice(tool_choice)
            # If already a gem model object, return as-is
            return tool_choice if tool_choice.is_a?(::Anthropic::Models::ToolChoiceAuto) ||
                                   tool_choice.is_a?(::Anthropic::Models::ToolChoiceAny) ||
                                   tool_choice.is_a?(::Anthropic::Models::ToolChoiceTool) ||
                                   tool_choice.is_a?(::Anthropic::Models::ToolChoiceNone)

            case tool_choice
            when "required"
              # Create ToolChoiceAny model for forcing tool use
              ::Anthropic::Models::ToolChoiceAny.new(type: :any)
            when "auto"
              # Create ToolChoiceAuto model for letting model decide
              ::Anthropic::Models::ToolChoiceAuto.new(type: :auto)
            when Hash
              choice_hash = tool_choice.deep_symbolize_keys

              # If has type field, create appropriate model
              if choice_hash[:type]
                case choice_hash[:type].to_sym
                when :any
                  ::Anthropic::Models::ToolChoiceAny.new(**choice_hash)
                when :auto
                  ::Anthropic::Models::ToolChoiceAuto.new(**choice_hash)
                when :tool
                  ::Anthropic::Models::ToolChoiceTool.new(**choice_hash)
                when :none
                  ::Anthropic::Models::ToolChoiceNone.new(**choice_hash)
                else
                  choice_hash
                end
              # Convert { name: "..." } to ToolChoiceTool
              elsif choice_hash[:name]
                ::Anthropic::Models::ToolChoiceTool.new(type: :tool, name: choice_hash[:name])
              else
                choice_hash
              end
            else
              tool_choice
            end
          end

          # Merges consecutive same-role messages into single messages with multiple content blocks.
          #
          # Required by Anthropic API - consecutive messages with the same role must be combined.
          #
          # @param messages [Array<Hash>]
          # @return [Array<Hash>]
          def normalize_messages(messages)
            return messages unless messages.is_a?(Array)

            grouped = []

            messages.each do |msg|
              msg_hash = msg.is_a?(Hash) ? msg.deep_symbolize_keys : { role: :user, content: msg }

              # Extract role
              role = msg_hash[:role]&.to_sym || :user

              # Determine content
              if msg_hash.key?(:content)
                # Has explicit content key
                content = normalize_content(msg_hash[:content])
              elsif msg_hash.key?(:role) && msg_hash.keys.size > 1
                # Has role + other keys (e.g., {role: "assistant", text: "..."})
                # Treat everything except :role as content
                content = normalize_content(msg_hash.except(:role))
              elsif !msg_hash.key?(:role)
                # No role or content - treat entire hash as content
                content = normalize_content(msg_hash)
              else
                # Only has role, no content
                content = []
              end

              if grouped.empty? || grouped.last[:role] != role
                grouped << { role: role, content: content }
              else
                # Merge content from consecutive same-role messages
                grouped.last[:content] += content
              end
            end

            grouped
          end

          # Converts system content shortcuts to API format.
          #
          # Handles string, hash, or array inputs. Strings pass through unchanged
          # since Anthropic accepts both string and structured formats.
          #
          # @param system [String, Array, Hash]
          # @return [String, Array]
          def normalize_system(system)
            case system
            when String
              # Keep strings as-is - Anthropic accepts both string and array
              system
            when Array
              # Normalize array of system blocks
              system.map { |block| normalize_system_block(block) }
            when Hash
              # Single hash becomes array with one block
              [ normalize_system_block(system) ]
            else
              system
            end
          end

          # @param block [String, Hash]
          # @return [Hash]
          def normalize_system_block(block)
            case block
            when String
              { type: "text", text: block }
            when Hash
              hash = block.deep_symbolize_keys
              # Add type if missing and can be inferred
              hash[:type] ||= "text" if hash[:text]
              hash
            else
              block
            end
          end

          # Expands content shortcuts into structured content block arrays.
          #
          # Handles multiple input formats:
          # - String → `[{type: "text", text: "..."}]`
          # - Hash with multiple keys → separate blocks per content type
          # - Array → normalized items
          #
          # @param content [String, Array, Hash]
          # @return [Array<Hash>]
          def normalize_content(content)
            case content
            when String
              # String → array with single text block
              [ { type: "text", text: content } ]
            when Array
              # Normalize each item in the array
              content.flat_map { |item| normalize_content_item(item) }
            when Hash
              # Check if hash has multiple content keys (text, image, document)
              # If so, expand into separate content blocks
              hash = content.deep_symbolize_keys
              content_keys = [ :text, :image, :document ]
              found_keys = content_keys & hash.keys

              if found_keys.size > 1
                # Multiple content types - expand into array
                found_keys.flat_map { |key| normalize_content_item({ key => hash[key] }) }
              else
                # Single content item
                [ normalize_content_item(content) ]
              end
            when nil
              []
            else
              # Pass through other types (might be gem objects already)
              [ content ]
            end
          end

          # Infers content block type from hash keys or converts string to text block.
          #
          # @param item [String, Hash]
          # @return [Hash]
          def normalize_content_item(item)
            case item
            when String
              { type: "text", text: item }
            when Hash
              hash = item.deep_symbolize_keys

              # If type is specified, return as-is
              return hash if hash[:type]

              # Type inference based on keys
              if hash[:text]
                { type: "text" }.merge(hash)
              elsif hash[:image]
                # Normalize image source format
                source = normalize_source(hash[:image])
                { type: "image", source: source }.merge(hash.except(:image))
              elsif hash[:document]
                # Normalize document source format
                source = normalize_source(hash[:document])
                { type: "document", source: source }.merge(hash.except(:document))
              elsif hash[:tool_use_id]
                # Tool result content
                { type: "tool_result" }.merge(hash)
              elsif hash[:id] && hash[:name] && hash[:input]
                # Tool use content
                { type: "tool_use" }.merge(hash)
              else
                # Unknown format - return as-is and let gem validate
                hash
              end
            else
              # Pass through (might be gem object)
              item
            end
          end

          # Converts image/document source shortcuts to API structure.
          #
          # Handles multiple formats:
          # - Regular URL → `{type: "url", url: "..."}`
          # - Data URI → `{type: "base64", media_type: "...", data: "..."}`
          # - Hash with base64 → `{type: "base64", media_type: "...", data: "..."}`
          #
          # @param source [String, Hash]
          # @return [Hash]
          def normalize_source(source)
            case source
            when String
              # Check if it's a data URI (e.g., "data:image/png;base64,...")
              if source.start_with?("data:")
                parse_data_uri(source)
              else
                # Regular URL → wrap in url source type
                { type: "url", url: source }
              end
            when Hash
              hash = source.deep_symbolize_keys
              # Already has type → return as-is
              return hash if hash[:type]

              # Has base64 data → add type
              if hash[:data] && hash[:media_type]
                { type: "base64" }.merge(hash)
              else
                # Unknown format → return as-is
                hash
              end
            else
              source
            end
          end

          # Extracts media type and data from data URI.
          #
          # Expected format: `data:[<media type>][;base64],<data>`
          #
          # @param data_uri [String] e.g., "data:image/png;base64,iVBORw0..."
          # @return [Hash] `{type: "base64", media_type: "...", data: "..."}`
          def parse_data_uri(data_uri)
            # Extract media type and data from data URI
            # Format: data:[<media type>][;base64],<data>
            match = data_uri.match(%r{\Adata:([^;,]+)(?:;base64)?,(.+)\z})

            if match
              {
                type: "base64",
                media_type: match[1],
                data: match[2]
              }
            else
              # Invalid data URI - return as URL fallback
              { type: "url", url: data_uri }
            end
          end

          # Converts single-element content arrays back to string shorthand.
          #
          # Reduces payload size by reversing the expansion done by normalize methods.
          #
          # @param hash [Hash]
          # @return [Hash]
          def compress_content(hash)
            return hash unless hash.is_a?(Hash)

            # Compress message content
            hash[:messages]&.each do |msg|
              compress_message_content!(msg)
            end

            # Compress system content
            if hash[:system].is_a?(Array)
              hash[:system] = compress_system_content(hash[:system])
            end

            hash
          end

          # Converts single text block arrays to string shorthand.
          #
          # `[{type: "text", text: "hello"}]` → `"hello"`
          #
          # @param msg [Hash] message with :content key
          # @return [void]
          def compress_message_content!(msg)
            content = msg[:content]
            return unless content.is_a?(Array)

            # Single text block → string shorthand
            if content.one? && content.first.is_a?(Hash) && content.first[:type] == "text"
              msg[:content] = content.first[:text]
            end
          end

          # Cleans up serialized request for API submission.
          #
          # Removes response-only fields, applies content compression,
          # removes provider-internal fields, and removes default values.
          # Note: max_tokens is kept even if it matches default as Anthropic API requires it.
          #
          # @param hash [Hash] serialized request
          # @param defaults [Hash] default values to remove
          # @param gem_object [Object] original gem object (unused but for consistency)
          # @return [Hash] cleaned request hash
          def cleanup_serialized_request(hash, defaults, gem_object = nil)
            # Remove response-only fields from messages
            if hash[:messages]
              hash[:messages].each do |msg|
                msg.delete(:id)
                msg.delete(:model)
                msg.delete(:stop_reason)
                msg.delete(:stop_sequence)
                msg.delete(:type)
                msg.delete(:usage)
              end
            end

            # Apply content compression for API efficiency
            compress_content(hash)

            # Remove provider-internal fields and empty arrays
            hash.delete(:stop_sequences) if hash[:stop_sequences] == []
            hash.delete(:mcp_servers) if hash[:mcp_servers] == []
            hash.delete(:tool_choice) if hash[:tool_choice].nil?  # Don't send null tool_choice

            # Remove default values (except max_tokens which is required by API)
            defaults.each do |key, value|
              next if key == :max_tokens  # Anthropic API requires max_tokens
              hash.delete(key) if hash[key] == value
            end

            hash
          end

          private

          # Converts single text block to string.
          #
          # @param system [Array]
          # @return [String, Array]
          def compress_system_content(system)
            return system unless system.is_a?(Array)

            # Single text block → string shorthand
            if system.one? && system.first.is_a?(Hash) && system.first[:type] == "text"
              system.first[:text]
            else
              system
            end
          end
        end
      end
    end
  end
end
