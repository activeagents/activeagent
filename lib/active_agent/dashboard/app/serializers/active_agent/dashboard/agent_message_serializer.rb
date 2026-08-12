# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Serializes AgentMessage records for the shared InteractionStream UI
    # (Interactions view and the agent Conversation History run detail).
    class AgentMessageSerializer
      def self.call(message)
        {
          id: message.id,
          role: message.role,
          content: message.content,
          tool_name: message.tool_name,
          tool_call_id: message.tool_call_id,
          tool_calls: message.tool_calls_data,
          tool_arguments: message.tool_arguments.presence,
          tool_result: message.tool_result,
          duration_ms: message.metadata&.dig("duration_ms"),
          content_checksum: message.content_checksum,
          created_at: message.created_at.iso8601(3)
        }
      end
    end
  end
end
