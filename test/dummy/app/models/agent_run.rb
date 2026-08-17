# frozen_string_literal: true

# Copied from solid_agent's install generator template — see AgentContext.
# The fingerprint helpers degrade when the resolved solid_agent predates
# SolidAgent::RunFingerprint, so the dummy app boots on either.
class AgentRun < ApplicationRecord
  belongs_to :runnable, polymorphic: true, optional: true

  STATUSES = %w[pending running complete failed cancelled].freeze

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_agent, ->(agent_name) { where(agent_name: agent_name) }
  scope :for_action, ->(action_name) { where(action_name: action_name) }
  scope :with_trace, ->(trace_id) { where(trace_id: trace_id) }
  scope :for_status, ->(status) { where(status: status) }

  STATUSES.each do |status_name|
    define_method("#{status_name}?") { status == status_name }
  end

  def in_progress?
    pending? || running?
  end

  def finished?
    complete? || failed? || cancelled?
  end

  def start!
    update!(status: "running", started_at: Time.current)
  end

  def complete!(output: nil, metadata: {}, input_tokens: nil, output_tokens: nil)
    update!(
      status: "complete",
      output: output,
      output_metadata: (output_metadata || {}).merge(metadata),
      input_tokens: input_tokens || self.input_tokens,
      output_tokens: output_tokens || self.output_tokens,
      completed_at: Time.current,
      duration_ms: calculated_duration_ms(fallback_end: Time.current)
    )
  end

  def fail!(error)
    update!(
      status: "failed",
      error_message: error.respond_to?(:message) ? error.message : error.to_s,
      completed_at: Time.current,
      duration_ms: calculated_duration_ms(fallback_end: Time.current)
    )
  end

  def cancel!
    return false if finished?

    update!(status: "cancelled", completed_at: Time.current)
    true
  end

  def append_event(kind:, label:, eid: nil, status: "done", detail: nil, duration_ms: nil)
    event = {
      "at" => Time.current.iso8601(3),
      "eid" => eid,
      "kind" => kind.to_s,
      "label" => label.to_s,
      "status" => status.to_s
    }.compact
    event["detail"] = detail.to_s.byteslice(0, 1200).to_s.scrub if detail
    event["duration_ms"] = duration_ms if duration_ms
    current = self.class.where(id: id).pick(:events) || []
    update_column(:events, current + [ event ])
    event
  end

  def record_instructions(instructions)
    return unless defined?(SolidAgent::RunFingerprint)

    self.instructions_digest = SolidAgent::RunFingerprint.digest(instructions)
  end

  def instructions_codename
    return unless defined?(SolidAgent::RunFingerprint)

    SolidAgent::RunFingerprint.codename(instructions_digest)
  end

  def total_tokens
    input_tokens.to_i + output_tokens.to_i
  end

  def calculated_duration_ms(fallback_end: nil)
    return duration_ms if duration_ms.present?

    finish = completed_at || fallback_end
    return nil unless started_at && finish

    ((finish - started_at) * 1000).to_i
  end
end
