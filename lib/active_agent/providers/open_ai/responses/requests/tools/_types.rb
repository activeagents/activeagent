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
                  hash = value.deep_symbolize_keys
                  type = hash[:type]&.to_sym

                  case type
                  when :function
                    FunctionTool.new(**hash)
                  when :custom
                    CustomTool.new(**hash)
                  when :web_search, :web_search_2025_08_26
                    WebSearchTool.new(**hash)
                  when :web_search_preview, :web_search_preview_2025_03_11
                    WebSearchPreviewTool.new(**hash)
                  when :code_interpreter
                    CodeInterpreterTool.new(**hash)
                  when :file_search
                    FileSearchTool.new(**hash)
                  when :computer_use_preview
                    ComputerTool.new(**hash)
                  when :mcp
                    McpTool.new(**hash)
                  when :image_generation
                    ImageGenerationTool.new(**hash)
                  when :local_shell
                    LocalShellTool.new(**hash)
                  else
                    raise ArgumentError, "Unknown tool type: #{type.inspect}"
                  end
                when nil
                  nil
                else
                  raise ArgumentError, "Cannot cast #{value.class} to Tool (expected Base, Hash, or nil)"
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
                  raise ArgumentError, "Cannot serialize #{value.class} as Tool"
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
