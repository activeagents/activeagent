# frozen_string_literal: true

require_relative "base"
require_relative "code_interpreter_tool"
require_relative "computer_tool"
require_relative "custom_tool"
require_relative "file_search_tool"
require_relative "function_tool"
require_relative "image_generation_tool"
require_relative "local_shell_tool"
require_relative "mcp_tool"
require_relative "web_search_preview_tool"
require_relative "web_search_tool"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Type for collection of tools
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

            # Type for individual tool
            class ToolType < ActiveModel::Type::Value
              def cast(value)
                case value
                when Base
                  value
                when Hash
                  type = value[:type]&.to_s || value["type"]&.to_s

                  case type
                  when "function"
                    FunctionTool.new(**value.symbolize_keys)
                  when "custom"
                    CustomTool.new(**value.symbolize_keys)
                  when "web_search", "web_search_2025_08_26"
                    WebSearchTool.new(**value.symbolize_keys)
                  when "web_search_preview", "web_search_preview_2025_03_11"
                    WebSearchPreviewTool.new(**value.symbolize_keys)
                  when "code_interpreter"
                    CodeInterpreterTool.new(**value.symbolize_keys)
                  when "file_search"
                    FileSearchTool.new(**value.symbolize_keys)
                  when "computer_use_preview"
                    ComputerTool.new(**value.symbolize_keys)
                  when "mcp"
                    McpTool.new(**value.symbolize_keys)
                  when "image_generation"
                    ImageGenerationTool.new(**value.symbolize_keys)
                  when "local_shell"
                    LocalShellTool.new(**value.symbolize_keys)
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
                when Base
                  value.serialize
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
          end
        end
      end
    end
  end
end
