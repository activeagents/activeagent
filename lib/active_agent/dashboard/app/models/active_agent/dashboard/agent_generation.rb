# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # One LLM generation call within an agent conversation context. From the
    # solid_agent install generator, extended with trace_id (joins to
    # active_agent_telemetry_traces) and the SolidAgent provenance hash.
    class AgentGeneration < ApplicationRecord
      belongs_to :agent_context

      scope :recent, -> { order(created_at: :desc) }
      scope :by_model, ->(model) { where(model: model) }
      scope :with_tool_calls, -> { where.not(tool_calls: []) }
      scope :with_trace, ->(trace_id) { where(trace_id: trace_id) }

      def total_tokens
        input_tokens + output_tokens
      end

      def has_tool_calls?
        tool_calls.present? && tool_calls.any?
      end

      def completed?
        finish_reason == "stop"
      end

      def truncated?
        finish_reason == "length"
      end

      # Provider prompt-cache hit on this generation?
      def cache_hit?
        cached_tokens.to_i.positive?
      end

      # Extended thinking captured?
      def thinking?
        reasoning_tokens.to_i.positive?
      end

      # The telemetry trace this generation belongs to, when recorded.
      def telemetry_trace
        return nil if trace_id.blank?

        ActiveAgent::Dashboard.trace_model.find_by(trace_id: trace_id)
      end
    end
  end
end
