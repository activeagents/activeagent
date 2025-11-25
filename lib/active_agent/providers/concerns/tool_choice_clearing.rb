# frozen_string_literal: true

module ActiveAgent
  module Providers
    # Provides unified logic for clearing tool_choice after tool execution.
    #
    # When a tool_choice is set to "required" or to a specific tool name,
    # it forces the model to use that tool. After the tool is executed,
    # we need to clear the tool_choice to prevent infinite loops where
    # the model keeps calling the same tool repeatedly.
    #
    # Each provider implements:
    # - `extract_used_function_names`: Returns array of tool names that have been called
    # - `tool_choice_forces_required?`: Returns true if tool_choice forces any tool use
    # - `tool_choice_forces_specific?`: Returns [true, name] if tool_choice forces specific tool
    module ToolChoiceClearing
      extend ActiveSupport::Concern

      # @api private
      def prepare_prompt_request_tools
        return unless request.tool_choice

        functions_used = extract_used_function_names

        # Clear if forcing required and any tool was used
        if tool_choice_forces_required? && functions_used.any?
          request.tool_choice = nil
          return
        end

        # Clear if forcing specific tool and that tool was used
        forces_specific, tool_name = tool_choice_forces_specific?
        if forces_specific && tool_name && functions_used.include?(tool_name)
          request.tool_choice = nil
        end
      end

      private

      # Extracts the list of function names that have been called.
      #
      # @return [Array<String>] function names
      def extract_used_function_names
        raise NotImplementedError, "#{self.class} must implement #extract_used_function_names"
      end

      # Returns true if tool_choice forces any tool to be used (e.g., "required", "any").
      #
      # @return [Boolean]
      def tool_choice_forces_required?
        raise NotImplementedError, "#{self.class} must implement #tool_choice_forces_required?"
      end

      # Returns [true, tool_name] if tool_choice forces a specific tool, [false, nil] otherwise.
      #
      # @return [Array<Boolean, String|nil>]
      def tool_choice_forces_specific?
        raise NotImplementedError, "#{self.class} must implement #tool_choice_forces_specific?"
      end
    end
  end
end
