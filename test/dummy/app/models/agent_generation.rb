# frozen_string_literal: true

# Copied from solid_agent's install generator template — see AgentContext.
class AgentGeneration < ApplicationRecord
  belongs_to :agent_context

  scope :recent, -> { order(created_at: :desc) }
  scope :by_model, ->(model) { where(model: model) }
  scope :with_trace, ->(trace_id) { where(trace_id: trace_id) }
  scope :completed, -> { where(finish_reason: "stop") }

  def total_tokens
    input_tokens + output_tokens
  end

  def cache_hit?
    cached_tokens.to_i.positive?
  end

  def thinking?
    reasoning_tokens.to_i.positive?
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

  def ended_with_tool_calls?
    finish_reason == "tool_calls"
  end

  def estimated_cost(input_price_per_million: nil, output_price_per_million: nil)
    if input_price_per_million && output_price_per_million
      input_cost = (input_tokens / 1_000_000.0) * input_price_per_million
      output_cost = (output_tokens / 1_000_000.0) * output_price_per_million
      input_cost + output_cost
    elsif defined?(SolidAgent::ModelPricing)
      SolidAgent::ModelPricing.estimate(model: model, input_tokens: input_tokens, output_tokens: output_tokens)
    end
  end
end
