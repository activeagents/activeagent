# frozen_string_literal: true

module ActionAgent
  # Concern for adding session recording to models that track browser interactions
  #
  # Include this in models like AgentRun or SandboxSession to enable
  # automatic session recording for playback and handoff.
  #
  # Usage:
  #   class AgentRun < ApplicationRecord
  #     include SessionRecordable
  #   end
  #
  #   # Start recording
  #   run.start_session_recording!
  #
  #   # Record an action
  #   run.record_browser_action!(type: :click, selector: "#submit", screenshot: png_data)
  #
  #   # Complete recording
  #   run.complete_session_recording!
  #
  module SessionRecordable
    extend ActiveSupport::Concern

    included do
      has_one :session_recording, dependent: :destroy
    end

    # Start a new session recording
    def start_session_recording!(name: nil)
      return session_recording if session_recording&.recording?

      create_session_recording!(
        name: name || default_recording_name,
        status: :recording,
        metadata: { started_at: Time.current.iso8601 }
      )
    end

    # Record a browser action
    def record_browser_action!(type:, selector: nil, value: nil, screenshot: nil, dom_snapshot: nil, metadata: {})
      return unless session_recording&.recording?

      session_recording.record_action!(
        action_type: type.to_s,
        selector: selector,
        value: value,
        screenshot: screenshot,
        dom_snapshot: dom_snapshot,
        metadata: metadata
      )
    end

    # Complete the recording
    def complete_session_recording!
      session_recording&.complete!
    end

    # Fail the recording
    def fail_session_recording!(error_message = nil)
      session_recording&.fail!(error_message)
    end

    # Check if recording is active
    def recording_active?
      session_recording&.recording?
    end

    # Get the session recording service
    def recording_service
      return nil unless session_recording

      SessionRecordingService.new(session_recording)
    end

    private

    def default_recording_name
      prefix = if respond_to?(:name) && name.present?
        name.parameterize
      elsif respond_to?(:agent) && agent&.name
        agent.name.parameterize
      else
        "session"
      end

      "#{prefix}_#{Time.current.strftime('%Y%m%d_%H%M%S')}"
    end
  end
end
