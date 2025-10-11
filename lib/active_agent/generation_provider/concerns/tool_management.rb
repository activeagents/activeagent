# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module ToolManagement
      extend ActiveSupport::Concern

      def format_tools(tools)
        return nil if tools.blank?

        tools.map do |tool|
          format_single_tool(tool)
        end
      end

      def handle_actions(tool_calls)
        return [] if tool_calls.nil? || tool_calls.empty?

        tool_calls.map do |tool_call|
          parse_tool_call(tool_call)
        end.compact
      end

      protected

      def format_single_tool(tool)
        # Default implementation for OpenAI-style tools
        if tool["function"] || tool[:function]
          # Tool already has the correct structure
          tool
        else
          # Legacy format - wrap in function structure
          wrap_tool_in_function(tool)
        end
      end

      def wrap_tool_in_function(tool)
        {
          type: "function",
          function: {
            name: tool["name"] || tool[:name],
            description: tool["description"] || tool[:description],
            parameters: tool["parameters"] || tool[:parameters]
          }
        }
      end

      def parse_tool_call(tool_call)
        # Skip if no function information
        return nil if tool_call.nil?

        # Extract tool information based on provider format
        tool_id = extract_tool_id(tool_call)
        tool_name = extract_tool_name(tool_call)
        tool_params = extract_tool_params(tool_call)

        # Skip if no name found
        return nil if tool_name.blank?

        ActiveAgent::ActionPrompt::Action.new(
          id: tool_id,
          name: tool_name,
          params: tool_params
        )
      end

      def extract_tool_id(tool_call)
        tool_call["id"] || tool_call[:id]
      end

      def extract_tool_name(tool_call)
        # Try different paths for tool name
        tool_call.dig("function", "name") ||
          tool_call.dig(:function, :name) ||
          tool_call["name"] ||
          tool_call[:name]
      end

      def extract_tool_params(tool_call)
        # Try different paths for tool parameters/arguments
        args = tool_call.dig("function", "arguments") ||
               tool_call.dig(:function, :arguments) ||
               tool_call["arguments"] ||
               tool_call[:arguments] ||
               tool_call["input"] ||
               tool_call[:input]

        return nil if args.blank?

        # Parse JSON string if needed
        if args.is_a?(String)
          begin
            JSON.parse(args, symbolize_names: true)
          rescue JSON::ParserError
            nil
          end
        else
          args
        end
      end

      # Provider-specific tool format methods
      # Override these in specific providers

      def format_tools_for_anthropic(tools)
        # Anthropic-specific tool format
        tools.map do |tool|
          {
            name: extract_tool_name_from_schema(tool),
            description: extract_tool_description_from_schema(tool),
            input_schema: extract_tool_parameters_from_schema(tool)
          }
        end
      end

      def format_tools_for_openai(tools)
        # OpenAI-specific tool format (default)
        format_tools(tools)
      end

      private

      def extract_tool_name_from_schema(tool)
        tool["name"] || tool[:name] ||
        tool.dig("function", "name") || tool.dig(:function, "name") ||
        tool.dig("function", :name) || tool.dig(:function, :name)
      end

      def extract_tool_description_from_schema(tool)
        tool["description"] || tool[:description] ||
        tool.dig("function", "description") || tool.dig(:function, "description") ||
        tool.dig("function", :description) || tool.dig(:function, :description)
      end

      def extract_tool_parameters_from_schema(tool)
        tool["parameters"] || tool[:parameters] ||
        tool.dig("function", "parameters") || tool.dig(:function, "parameters") ||
        tool.dig("function", :parameters) || tool.dig(:function, :parameters)
      end
    end
  end
end
