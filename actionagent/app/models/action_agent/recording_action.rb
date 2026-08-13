# frozen_string_literal: true

module ActionAgent
  class RecordingAction < ApplicationRecord
    belongs_to :session_recording
    has_one :snapshot, class_name: "RecordingSnapshot", dependent: :nullify

    ACTION_TYPES = %w[
      navigate
      click
      type
      scroll
      snapshot
      select
      hover
      drag
      file_upload
      dialog
      evaluate
      wait
      form_fill
      key_press
      focus
      submit
      handoff
      user_action
      completion
    ].freeze

    validates :action_type, presence: true, inclusion: { in: ACTION_TYPES }
    validates :sequence, presence: true, uniqueness: { scope: :session_recording_id }
    validates :timestamp_ms, presence: true

    scope :ordered, -> { order(:sequence) }
    scope :with_screenshots, -> { where.not(screenshot_key: nil) }

    # Get the screenshot URL (signed URL from storage)
    def screenshot_url(expires_in: 15.minutes)
      return nil unless screenshot_key.present?

      SessionRecordingService.signed_url_for(screenshot_key, expires_in: expires_in)
    end

    # Get the DOM snapshot content
    def dom_snapshot_content
      return nil unless dom_snapshot_key.present?

      SessionRecordingService.fetch_snapshot(dom_snapshot_key)
    end

    # Format for API response
    def as_json_for_api
      {
        id: id,
        action_type: action_type,
        sequence: sequence,
        timestamp_ms: timestamp_ms,
        selector: selector,
        value: redacted_value,
        screenshot_url: screenshot_url,
        has_dom_snapshot: dom_snapshot_key.present?,
        metadata: safe_metadata,
        created_at: created_at.iso8601
      }
    end

    # Get browser state at this action (for handoff)
    def browser_state
      {
        url: extract_url,
        form_values: metadata["form_values"],
        scroll_position: metadata["scroll_position"],
        active_element: selector,
        action_type: action_type
      }
    end

    private

    def redacted_value
      return value unless should_redact?

      "[REDACTED]"
    end

    def should_redact?
      return false unless value.present?

      sensitive_patterns = [
        /password/i,
        /credit.?card/i,
        /cvv/i,
        /ssn/i,
        /social.?security/i,
        /\b\d{16}\b/, # Credit card numbers
        /\b\d{3}-\d{2}-\d{4}\b/ # SSN format
      ]

      selector_is_sensitive = sensitive_patterns.any? { |p| selector&.match?(p) }
      value_is_sensitive = sensitive_patterns.any? { |p| value.match?(p) }

      selector_is_sensitive || value_is_sensitive
    end

    def safe_metadata
      # Remove any sensitive data from metadata
      metadata.except("password", "credit_card", "cvv", "ssn")
    end

    def extract_url
      case action_type
      when "navigate"
        value
      else
        metadata["url"] || metadata["page_url"]
      end
    end
  end
end
