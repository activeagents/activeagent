# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module MessageFormatting
      extend ActiveSupport::Concern

      def provider_messages(messages)
        messages.map do |message|
          format_message(message)
        end
      end

      protected

      def format_message(message)
        base_message = {
          role: convert_role(message.role),
          content: format_content(message)
        }

        add_tool_fields(base_message, message)
        add_metadata_fields(base_message, message)

        base_message.compact
      end

      def convert_role(role)
        # Default role conversion - override in provider for specific mappings
        role.to_s
      end

      def format_content(message)
        # Handle multimodal content
        case message.content_type
        when "image_url"
          format_image_content(message)
        when "multipart/mixed", "array"
          format_multimodal_content(message)
        else
          message.content
        end
      end

      def format_image_content(message)
        # Default implementation - override in provider
        message.content
      end

      def format_multimodal_content(message)
        # Default implementation for multimodal content
        if message.content.is_a?(Array)
          message.content.map do |item|
            format_content_item(item)
          end
        else
          message.content
        end
      end

      def format_content_item(item)
        # Format individual content items in multimodal messages
        # Override in provider for specific formatting
        item
      end

      def add_tool_fields(base_message, message)
        # Add tool-specific fields based on role
        case message.role.to_s
        when "assistant"
          if message.action_requested && message.requested_actions.any?
            base_message[:tool_calls] = format_tool_calls(message.requested_actions)
          elsif message.raw_actions.present? && message.raw_actions.is_a?(Array)
            base_message[:tool_calls] = message.raw_actions
          end
        when "tool"
          base_message[:tool_call_id] = message.action_id if message.action_id
          base_message[:name] = message.action_name if message.action_name
        end
      end

      def add_metadata_fields(base_message, message)
        # Override to add provider-specific metadata
        # For example: message IDs, timestamps, etc.
      end

      def format_tool_calls(actions)
        # Default implementation - override in provider for specific format
        actions.map do |action|
          format_single_tool_call(action)
        end
      end

      def format_single_tool_call(action)
        # Default tool call format (OpenAI style)
        {
          type: "function",
          function: {
            name: action.name,
            arguments: action.params.is_a?(String) ? action.params : action.params.to_json
          },
          id: action.id
        }
      end
    end
  end
end
