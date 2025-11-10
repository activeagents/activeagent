# frozen_string_literal: true

require_relative "base"
require_relative "text"
require_relative "image"
require_relative "document"
require_relative "tool_use"
require_relative "tool_result"
require_relative "thinking"
require_relative "redacted_thinking"
require_relative "search_result"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          # Type for contents array (always an array of content items)
          class ContentsType < ActiveModel::Type::Value
            def initialize
              super
              @content_type = ContentType.new
            end

            def cast(value)
              case value
              when String
                # Convert string to array of text content
                [ Text.new(text: value) ]
              when Array
                # Array of content items - cast each item
                value.map { |item| @content_type.cast(item) }
              when Hash
                # Single hash becomes array with one content item
                [ @content_type.cast(value) ]
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Contents array"
              end
            end

            def serialize(value)
              case value
              when Array
                serialized = value.map { |item| @content_type.serialize(item) }
                # Compress single text item to string
                if serialized.one? && serialized.first.is_a?(Hash) && serialized.first[:type] == "text"
                  serialized.first[:text]
                else
                  serialized
                end
              when nil
                nil
              else
                # Should not happen if cast is working correctly, but handle gracefully
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          # Type for individual content items
          class ContentType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Base
                # Already a Content object, return as-is
                value
              when Hash
                hash = value.deep_symbolize_keys
                type = hash[:type]&.to_sym

                case type
                when :text
                  Text.new(**hash)
                when :image
                  Image.new(**hash)
                when :document
                  Document.new(**hash)
                when :tool_use
                  ToolUse.new(**hash)
                when :tool_result
                  ToolResult.new(**hash)
                when :thinking
                  Thinking.new(**hash)
                when :redacted_thinking
                  RedactedThinking.new(**hash)
                when :search_result
                  SearchResult.new(**hash)
                when nil
                  # No type specified - infer from keys present
                  if hash.key?(:text)
                    Text.new(**hash)
                  elsif hash.key?(:image)
                    # Move image key under source
                    Image.new(**hash.merge(source: hash.extract!(:image)))
                  elsif hash.key?(:document)
                    # Move document key under source
                    Document.new(**hash.merge(source: hash.extract!(:document)))
                  else
                    raise ArgumentError, "Cannot cast hash without type to Content: #{hash.inspect}"
                  end
                else
                  raise ArgumentError, "Unknown content type: #{type}"
                end
              when String
                # Plain text string becomes text content item
                Text.new(text: value)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Content"
              end
            end

            def serialize(value)
              case value
              when Base
                value.serialize
              when Hash
                value
              when String
                { type: "text", text: value }
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class} as Content"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end
        end
      end
    end
  end
end
