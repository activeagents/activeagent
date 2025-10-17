# frozen_string_literal: true

require_relative "content_blocks/base"
require_relative "content_blocks/text"
require_relative "content_blocks/image"
require_relative "content_blocks/document"
require_relative "content_blocks/tool_use"
require_relative "content_blocks/tool_result"
require_relative "content_blocks/thinking"
require_relative "content_blocks/redacted_thinking"
require_relative "content_blocks/search_result"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Types
          # Type for Messages array
          class MessagesType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Array
                value.map { |v| cast_message(v) }
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Messages array"
              end
            end

            def serialize(value)
              case value
              when Array
                value.map { |v| serialize_message(v) }
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end

            private

            def cast_message(value)
              case value
              when Messages::Base
                value
              when Hash
                role = value[:role]&.to_s || value["role"]&.to_s
                case role
                when "user"
                  Messages::User.new(**value.symbolize_keys)
                when "assistant"
                  Messages::Assistant.new(**value.symbolize_keys)
                else
                  raise ArgumentError, "Unknown message role: #{role}"
                end
              else
                raise ArgumentError, "Cannot cast #{value.class} to Message"
              end
            end

            def serialize_message(value)
              case value
              when Messages::Base
                value.to_h
              when Hash
                value
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end
          end

          # Type for Metadata
          class MetadataType < ActiveModel::Type::Value
            def cast(value)
              case value
              when Metadata
                value
              when Hash
                Metadata.new(**value.symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to Metadata"
              end
            end

            def serialize(value)
              case value
              when Metadata
                value.to_h
              when Hash
                value
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          # Type for ThinkingConfig
          class ThinkingConfigType < ActiveModel::Type::Value
            def cast(value)
              case value
              when ThinkingConfig::Base
                value
              when Hash
                type = value[:type]&.to_s || value["type"]&.to_s
                case type
                when "enabled"
                  ThinkingConfig::Enabled.new(**value.symbolize_keys)
                when "disabled"
                  ThinkingConfig::Disabled.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Unknown thinking config type: #{type}"
                end
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to ThinkingConfig"
              end
            end

            def serialize(value)
              case value
              when ThinkingConfig::Base
                value.to_h
              when Hash
                value
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          # Type for ToolChoice
          class ToolChoiceType < ActiveModel::Type::Value
            def cast(value)
              case value
              when ToolChoice::Base
                value
              when Hash
                type = value[:type]&.to_s || value["type"]&.to_s
                case type
                when "auto"
                  ToolChoice::Auto.new(**value.symbolize_keys)
                when "any"
                  ToolChoice::Any.new(**value.symbolize_keys)
                when "tool"
                  ToolChoice::Tool.new(**value.symbolize_keys)
                when "none"
                  ToolChoice::None.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Unknown tool choice type: #{type}"
                end
              when String
                # Allow string shortcuts like "auto", "any", "none"
                case value
                when "auto"
                  ToolChoice::Auto.new
                when "any"
                  ToolChoice::Any.new
                when "none"
                  ToolChoice::None.new
                else
                  raise ArgumentError, "Unknown tool choice: #{value}"
                end
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to ToolChoice"
              end
            end

            def serialize(value)
              case value
              when ToolChoice::Base
                value.to_h
              when Hash
                value
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          # Type for ContextManagementConfig
          class ContextManagementConfigType < ActiveModel::Type::Value
            def cast(value)
              case value
              when ContextManagementConfig
                value
              when Hash
                ContextManagementConfig.new(**value.symbolize_keys)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to ContextManagementConfig"
              end
            end

            def serialize(value)
              case value
              when ContextManagementConfig
                value.to_h
              when Hash
                value
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          # Type for ContainerParams
          class ContainerParamsType < ActiveModel::Type::Value
            def cast(value)
              case value
              when ContainerParams
                value
              when Hash
                ContainerParams.new(**value.symbolize_keys)
              when String
                # Allow string as container ID shortcut
                ContainerParams.new(id: value)
              when nil
                nil
              else
                raise ArgumentError, "Cannot cast #{value.class} to ContainerParams"
              end
            end

            def serialize(value)
              case value
              when ContainerParams
                value.to_h
              when Hash
                value
              when nil
                nil
              else
                raise ArgumentError, "Cannot serialize #{value.class}"
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          # Type for individual content blocks
          class ContentBlockType < ActiveModel::Type::Value
            def cast(value)
              case value
              when ContentBlocks::Base
                value
              when Hash
                type = value[:type]&.to_s || value["type"]&.to_s

                case type
                when "text"
                  ContentBlocks::Text.new(**value.symbolize_keys)
                when "image"
                  ContentBlocks::Image.new(**value.symbolize_keys)
                when "document"
                  ContentBlocks::Document.new(**value.symbolize_keys)
                when "tool_use"
                  ContentBlocks::ToolUse.new(**value.symbolize_keys)
                when "tool_result"
                  ContentBlocks::ToolResult.new(**value.symbolize_keys)
                when "thinking"
                  ContentBlocks::Thinking.new(**value.symbolize_keys)
                when "redacted_thinking"
                  ContentBlocks::RedactedThinking.new(**value.symbolize_keys)
                when "search_result"
                  ContentBlocks::SearchResult.new(**value.symbolize_keys)
                else
                  # Return hash as-is if type is unknown
                  value
                end
              when String
                # Plain text string becomes text content block
                ContentBlocks::Text.new(text: value)
              when nil
                nil
              else
                value
              end
            end

            def serialize(value)
              case value
              when ContentBlocks::Base
                value.to_h
              when Hash
                value
              when String
                { type: "text", text: value }
              when nil
                nil
              else
                value
              end
            end

            def deserialize(value)
              cast(value)
            end
          end

          # Type for content (string or array of content blocks)
          class ContentType < ActiveModel::Type::Value
            def initialize
              super
              @content_block_type = ContentBlockType.new
            end

            def cast(value)
              case value
              when String
                # Plain text string - keep as string
                value
              when Array
                # Array of content blocks - cast each block
                value.map { |block| @content_block_type.cast(block) }
              when nil
                nil
              else
                value
              end
            end

            def serialize(value)
              case value
              when String
                value
              when Array
                value.map { |block| @content_block_type.serialize(block) }
              when nil
                nil
              else
                value
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
