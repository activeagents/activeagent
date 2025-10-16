# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Types
            class ConversationType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Conversation
                  value
                when Hash
                  Conversation.new(**value.symbolize_keys)
                when String
                  value # Can be a conversation ID string
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Conversation"
                end
              end

              def serialize(value)
                case value
                when Conversation
                  value.to_h
                when Hash
                  value
                when String
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

            class PromptReferenceType < ActiveModel::Type::Value
              def cast(value)
                case value
                when PromptReference
                  value
                when Hash
                  PromptReference.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to PromptReference"
                end
              end

              def serialize(value)
                case value
                when PromptReference
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

            class ReasoningType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Reasoning
                  value
                when Hash
                  Reasoning.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Reasoning"
                end
              end

              def serialize(value)
                case value
                when Reasoning
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

            class StreamOptionsType < ActiveModel::Type::Value
              def cast(value)
                case value
                when StreamOptions
                  value
                when Hash
                  StreamOptions.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to StreamOptions"
                end
              end

              def serialize(value)
                case value
                when StreamOptions
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

            class TextType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Text
                  value
                when Hash
                  Text.new(**value.symbolize_keys)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Text"
                end
              end

              def serialize(value)
                case value
                when Text
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

            class ContentPartType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Inputs::ContentParts::Base
                  value
                when Hash
                  type = value[:type]&.to_s || value["type"]&.to_s

                  case type
                  when "input_text"
                    Inputs::ContentParts::InputText.new(**value.symbolize_keys)
                  when "input_image"
                    Inputs::ContentParts::InputImage.new(**value.symbolize_keys)
                  when "input_file"
                    Inputs::ContentParts::InputFile.new(**value.symbolize_keys)
                  else
                    # Return hash as-is if type is unknown
                    value
                  end
                when String
                  # Plain text string becomes input_text
                  Inputs::ContentParts::InputText.new(text: value)
                when nil
                  nil
                else
                  value
                end
              end

              def serialize(value)
                case value
                when Inputs::ContentParts::Base
                  value.to_h
                when Hash
                  value
                when String
                  { type: "input_text", text: value }
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

            class ContentType < ActiveModel::Type::Value
              def initialize
                super
                @content_part_type = ContentPartType.new
              end

              def cast(value)
                case value
                when String
                  # Plain text string - keep as string
                  value
                when Array
                  # Array of content parts - cast each part
                  value.map { |part| @content_part_type.cast(part) }
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
                  value.map { |part| @content_part_type.serialize(part) }
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

            class InputMessageType < ActiveModel::Type::Value
              def initialize
                super
                @content_part_type = ContentPartType.new
              end

              def cast(value)
                case value
                when Inputs::Base
                  value
                when Hash
                  role = value[:role]&.to_s || value["role"]&.to_s

                  # Handle content - can be string or array
                  if value[:content].is_a?(Array) || value["content"].is_a?(Array)
                    content = value[:content] || value["content"]
                    typed_content = content.map { |part| @content_part_type.cast(part) }
                    value = value.merge(content: typed_content)
                  end

                  case role
                  when "system"
                    Inputs::SystemMessage.new(**value.symbolize_keys)
                  when "user"
                    Inputs::UserMessage.new(**value.symbolize_keys)
                  when "assistant"
                    Inputs::AssistantMessage.new(**value.symbolize_keys)
                  when "tool"
                    Inputs::ToolMessage.new(**value.symbolize_keys)
                  else
                    # Return hash as-is if role is unknown
                    value
                  end
                when nil
                  nil
                else
                  value
                end
              end

              def serialize(value)
                case value
                when Inputs::Base
                  hash = value.to_h
                  # Serialize content array if present
                  if hash[:content].is_a?(Array)
                    hash[:content] = hash[:content].map { |part| @content_part_type.serialize(part) }
                  end
                  hash
                when Hash
                  value
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

            class InputType < ActiveModel::Type::Value
              def initialize
                super
                @input_message_type = InputMessageType.new
              end

              def cast(value)
                case value
                when String
                  value
                when Array
                  value.map { |item| @input_message_type.cast(item) }
                when Hash
                  # Single hash becomes array with one message
                  [ @input_message_type.cast(value) ]
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Input (expected String, Array, or Hash)"
                end
              end

              def serialize(value)
                case value
                when String
                  value
                when Array
                  value.map { |item| @input_message_type.serialize(item) }
                when Hash
                  @input_message_type.serialize(value)
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

            class ToolChoiceType < ActiveModel::Type::Value
              def cast(value)
                case value
                when ToolChoice
                  value
                when Hash
                  ToolChoice.new(**value.symbolize_keys)
                when String
                  ToolChoice.new(mode: value)
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to ToolChoice"
                end
              end

              def serialize(value)
                case value
                when ToolChoice
                  value.to_h
                when Hash
                  value
                when String
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

            class ToolType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Tools::Base
                  value
                when Hash
                  type = value[:type]&.to_s || value["type"]&.to_s

                  case type
                  when "function"
                    Tools::FunctionTool.new(**value.symbolize_keys)
                  when "custom"
                    Tools::CustomTool.new(**value.symbolize_keys)
                  when "web_search", "web_search_2025_08_26"
                    Tools::WebSearchTool.new(**value.symbolize_keys)
                  when "web_search_preview", "web_search_preview_2025_03_11"
                    Tools::WebSearchPreviewTool.new(**value.symbolize_keys)
                  when "code_interpreter"
                    Tools::CodeInterpreterTool.new(**value.symbolize_keys)
                  when "file_search"
                    Tools::FileSearchTool.new(**value.symbolize_keys)
                  when "computer_use_preview"
                    Tools::ComputerTool.new(**value.symbolize_keys)
                  when "mcp"
                    Tools::McpTool.new(**value.symbolize_keys)
                  when "image_generation"
                    Tools::ImageGenerationTool.new(**value.symbolize_keys)
                  when "local_shell"
                    Tools::LocalShellTool.new(**value.symbolize_keys)
                  else
                    # Return hash as-is if type is unknown
                    value
                  end
                when nil
                  nil
                else
                  value
                end
              end

              def serialize(value)
                case value
                when Tools::Base
                  value.to_h
                when Hash
                  value
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

            class ToolsType < ActiveModel::Type::Value
              def initialize
                super
                @tool_type = ToolType.new
              end

              def cast(value)
                return nil if value.nil?
                return [] if value == []

                array = Array(value)
                array.map { |tool| @tool_type.cast(tool) }
              end

              def serialize(value)
                return nil if value.nil?
                return [] if value == []

                array = Array(value)
                array.map { |tool| @tool_type.serialize(tool) }
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
end
