# frozen_string_literal: true

# What `rails generate solid_agent:install` writes into a host app.
#
# Copied from solid_agent's install generator template so the integration
# suite exercises the models a user actually gets, not a convenient stub. If
# an upstream change breaks this contract, test/integration/solid_agent is
# where it should surface.
class AgentContext < ApplicationRecord
  belongs_to :contextable, polymorphic: true, optional: true
  has_many :messages, class_name: "AgentMessage", dependent: :destroy
  has_many :generations, class_name: "AgentGeneration", dependent: :destroy

  validates :agent_name, presence: true
  validates :action_name, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_agent, ->(name) { where(agent_name: name) }
  scope :for_action, ->(name) { where(action_name: name) }
  scope :with_trace, ->(trace_id) { where(trace_id: trace_id) }

  def input_params
    options&.dig("input_params") || options&.dig(:input_params) || {}
  end

  def record_generation!(response, extra_attributes = {})
    usage = response.respond_to?(:usage) ? response.usage : nil

    generation = generations.create!({
      content: response.message&.content,
      model: response_value(response, :model),
      provider: response_value(response, :provider),
      finish_reason: response_value(response, :finish_reason),
      input_tokens: usage&.input_tokens || 0,
      output_tokens: usage&.output_tokens || 0,
      cached_tokens: response_value(usage, :cached_tokens) || 0,
      reasoning_tokens: response_value(usage, :reasoning_tokens) || 0,
      tool_calls: extract_tool_calls(response),
      raw_response: response_value(response, :raw_response),
      duration_seconds: extract_duration_seconds(response, usage)
    }.merge(extra_attributes))

    increment!(:total_input_tokens, generation.input_tokens)
    increment!(:total_output_tokens, generation.output_tokens)

    add_assistant_message(response.message&.content, metadata: { "tool_calls" => generation.tool_calls })

    generation
  end

  def record_generation_with_provenance!(response, provenance)
    provenance = (provenance || {}).deep_stringify_keys

    record_generation!(response, trace_id: provenance["trace_id"], provenance: provenance)
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

  private

  def response_value(response, method)
    response.respond_to?(method) ? response.public_send(method) : nil
  end

  def extract_duration_seconds(response, usage)
    return response.duration if response.respond_to?(:duration) && response.duration

    duration_ms = usage.respond_to?(:duration_ms) ? usage.duration_ms : nil
    duration_ms ? duration_ms / 1000.0 : nil
  end

  def extract_tool_calls(response)
    message = response.message
    return [] unless message.respond_to?(:tool_calls) && message.tool_calls.present?

    message.tool_calls.map do |tc|
      {
        id: tc.respond_to?(:id) ? tc.id : nil,
        name: tc.respond_to?(:name) ? tc.name : nil,
        arguments: tc.respond_to?(:arguments) ? tc.arguments : nil
      }
    end
  end
end
