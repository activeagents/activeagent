# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Conversation context persisted by SolidAgent::HasContext — one row per
    # (contextable, agent, action). On this platform the contextable is the
    # dashboard Agent record, so a context is that agent's interaction stream.
    #
    # Based on the solid_agent install generator's AgentContext, extended with
    # record_generation_with_provenance! (the concern's duck-typed extension
    # point) so each generation carries the telemetry trace_id and provenance.
    class AgentContext < ApplicationRecord
      belongs_to :contextable, polymorphic: true, optional: true
      has_many :messages, class_name: "AgentMessage", dependent: :destroy
      has_many :generations, class_name: "AgentGeneration", dependent: :destroy

      validates :agent_name, presence: true
      validates :action_name, presence: true

      scope :recent, -> { order(updated_at: :desc) }
      scope :for_agent, ->(name) { where(agent_name: name) }
      scope :for_action, ->(name) { where(action_name: name) }
      scope :with_trace, ->(trace_id) { where(trace_id: trace_id) }
      scope :for_agents, ->(agents) { where(contextable_type: Agent.polymorphic_name, contextable_id: agents.select(:id)) }

      # Records a generation response and updates token counts.
      #
      # Defensive against response objects that don't expose provider/duration
      # (activeagent 1.0.3 responses don't) — solid_agent's stock template would
      # raise (and silently drop the generation) on those.
      def record_generation!(response, extra_attributes = {})
        usage = response.respond_to?(:usage) ? response.usage : nil

        generation = generations.create!({
          content: response.message&.content,
          model: value_if_responds(response, :model),
          provider: value_if_responds(response, :provider),
          finish_reason: value_if_responds(response, :finish_reason),
          input_tokens: usage&.input_tokens || 0,
          output_tokens: usage&.output_tokens || 0,
          cached_tokens: value_if_responds(usage, :cached_tokens) || 0,
          reasoning_tokens: value_if_responds(usage, :reasoning_tokens) || 0,
          tool_calls: extract_tool_calls(response),
          raw_response: value_if_responds(response, :raw_response),
          duration_seconds: extract_duration_seconds(response, usage)
        }.merge(extra_attributes))

        increment!(:total_input_tokens, generation.input_tokens)
        increment!(:total_output_tokens, generation.output_tokens)

        add_assistant_message(response.message&.content, metadata: { "tool_calls" => generation.tool_calls })

        generation
      end

      # Called by SolidAgent::HasContext when defined: persists the generation
      # together with its provenance hash and the telemetry trace_id, so
      # conversation records join to active_agent_telemetry_traces.
      def record_generation_with_provenance!(response, provenance)
        provenance = (provenance || {}).deep_stringify_keys

        record_generation!(
          response,
          trace_id: provenance["trace_id"],
          provenance: provenance
        )
      end

      def add_user_message(content, **attributes)
        messages.create!(role: "user", content: content, **attributes)
      end

      def add_assistant_message(content, **attributes)
        messages.create!(role: "assistant", content: content, **attributes)
      end

      def add_system_message(content)
        messages.create!(role: "system", content: content)
      end

      def add_tool_message(tool_call_id:, tool_name:, result:, arguments: nil, duration_ms: nil)
        messages.create!(
          role: "tool",
          tool_call_id: tool_call_id,
          tool_name: tool_name,
          tool_result: result,
          tool_arguments: arguments.presence || {},
          metadata: duration_ms ? { "duration_ms" => duration_ms } : {},
          content: result.is_a?(String) ? result : result.to_json
        )
      end

      def total_tokens
        total_input_tokens + total_output_tokens
      end

      def input_params
        options&.dig("input_params") || {}
      end

      private

      def value_if_responds(response, method)
        response.respond_to?(method) ? response.public_send(method) : nil
      end

      def extract_duration_seconds(response, usage)
        return response.duration if response.respond_to?(:duration) && response.duration

        duration_ms = usage&.respond_to?(:duration_ms) ? usage.duration_ms : nil
        duration_ms ? duration_ms / 1000.0 : nil
      end

      def extract_tool_calls(response)
        message = response.message
        return [] unless message.respond_to?(:tool_calls)

        tool_calls = message.tool_calls
        return [] if tool_calls.blank?

        tool_calls.map do |tc|
          {
            id: value_if_responds(tc, :id),
            name: value_if_responds(tc, :name),
            arguments: value_if_responds(tc, :arguments)
          }
        end
      end
    end
  end
end
