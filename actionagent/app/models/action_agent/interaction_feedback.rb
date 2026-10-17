# frozen_string_literal: true

module ActionAgent
  # Feedback is attached to a trace primary key, so tenant ownership follows
  # the trace even when two tenants report the same external trace_id.
  class InteractionFeedback < ApplicationRecord
    belongs_to :telemetry_trace, class_name: "ActionAgent::TelemetryTrace"
    validates :feedback_id, presence: true, length: { maximum: 128 }, uniqueness: { scope: :telemetry_trace_id }
    validates :rating, inclusion: { in: %w[positive negative] }
    validates :comment, length: { maximum: 5000 }
    validates :span_id, length: { maximum: 128 }
    validates :user_reference, length: { maximum: 255 }
    validate :span_belongs_to_trace

    private

    def span_belongs_to_trace
      return if span_id.blank? || telemetry_trace.nil?
      return if Array(telemetry_trace.spans).any? { |span| span["span_id"] == span_id }

      errors.add(:span_id, "must belong to the trace")
    end
  end
end
