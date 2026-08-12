# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # A single message in an agent conversation context (user, assistant,
    # system, or tool). From the solid_agent install generator; the provenance
    # and content_checksum columns are populated automatically by
    # SolidAgent::HasContext.
    class AgentMessage < ApplicationRecord
      belongs_to :agent_context

      validates :role, presence: true, inclusion: { in: %w[user assistant system tool] }

      scope :by_role, ->(role) { where(role: role) }
      scope :user_messages, -> { by_role("user") }
      scope :assistant_messages, -> { by_role("assistant") }
      scope :chronological, -> { order(created_at: :asc) }

      # Converts the message to a hash format for ActiveAgent prompts
      def to_message_hash
        hash = { role: role, content: content }
        hash[:tool_calls] = tool_calls_data if role == "assistant" && tool_calls_data.present?

        if role == "tool"
          hash[:tool_call_id] = tool_call_id
          hash[:name] = tool_name
        end

        hash
      end

      def tool_calls_data
        metadata&.dig("tool_calls") || []
      end

      def tool_call?
        role == "assistant" && tool_calls_data.present?
      end

      def tool_result?
        role == "tool"
      end
    end
  end
end
