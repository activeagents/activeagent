# frozen_string_literal: true

module ActionAgent
  # Service for managing browser session recordings
  # Captures agent browser interactions for replay and handoff to human users
  class SessionRecordingService
    class RecordingError < StandardError; end

    attr_reader :recording

    def initialize(recording = nil)
      @recording = recording
    end

    # Start a new recording session
    def self.start(agent_run: nil, sandbox_session: nil, name: nil)
      recording = SessionRecording.start!(
        agent_run: agent_run,
        sandbox_session: sandbox_session,
        name: name
      )

      new(recording)
    end

    # Find or create a recording for a context
    def self.for_context(agent_run: nil, sandbox_session: nil)
      recording = SessionRecording.recording.find_by(
        agent_run: agent_run,
        sandbox_session: sandbox_session
      )

      recording ? new(recording) : start(agent_run: agent_run, sandbox_session: sandbox_session)
    end

    # Record a browser navigation
    def navigate(url:, screenshot: nil)
      record_action(
        action_type: "navigate",
        value: url,
        screenshot: screenshot,
        metadata: { url: url }
      )
    end

    # Record a click action
    def click(selector:, screenshot: nil, metadata: {})
      record_action(
        action_type: "click",
        selector: selector,
        screenshot: screenshot,
        metadata: metadata.merge(element: selector)
      )
    end

    # Record a type/input action
    def type(selector:, text:, screenshot: nil, metadata: {})
      record_action(
        action_type: "type",
        selector: selector,
        value: text,
        screenshot: screenshot,
        metadata: metadata
      )
    end

    # Record a form fill (multiple fields)
    def fill_form(fields:, screenshot: nil)
      record_action(
        action_type: "form_fill",
        value: fields.to_json,
        screenshot: screenshot,
        metadata: { fields: fields, field_count: fields.size }
      )
    end

    # Record a key press
    def key_press(key:, screenshot: nil)
      record_action(
        action_type: "key_press",
        value: key,
        screenshot: screenshot
      )
    end

    # Record a scroll action
    def scroll(position:, screenshot: nil)
      record_action(
        action_type: "scroll",
        metadata: { scroll_position: position },
        screenshot: screenshot
      )
    end

    # Record a hover action
    def hover(selector:, screenshot: nil)
      record_action(
        action_type: "hover",
        selector: selector,
        screenshot: screenshot
      )
    end

    # Record a select option action
    def select_option(selector:, values:, screenshot: nil)
      record_action(
        action_type: "select",
        selector: selector,
        value: values.join(", "),
        screenshot: screenshot,
        metadata: { values: values }
      )
    end

    # Record a file upload
    def file_upload(paths:, screenshot: nil)
      record_action(
        action_type: "file_upload",
        value: paths.join(", "),
        screenshot: screenshot,
        metadata: { paths: paths }
      )
    end

    # Record a dialog interaction
    def dialog(accept:, text: nil, screenshot: nil)
      record_action(
        action_type: "dialog",
        value: text,
        screenshot: screenshot,
        metadata: { accepted: accept, prompt_text: text }
      )
    end

    # Record a JavaScript evaluation
    def evaluate(function:, result: nil, screenshot: nil)
      record_action(
        action_type: "evaluate",
        value: function,
        screenshot: screenshot,
        metadata: { result: result&.to_s&.truncate(1000) }
      )
    end

    # Capture a manual snapshot (screenshot + DOM)
    def capture_snapshot(screenshot: nil, dom: nil, full_page: false)
      snapshot_type = full_page ? "full_page" : "snapshot"

      record_action(
        action_type: "snapshot",
        screenshot: screenshot,
        dom_snapshot: dom,
        metadata: { full_page: full_page }
      )
    end

    # Capture browser state for handoff
    def capture_handoff_state(url:, cookies: nil, local_storage: nil, session_storage: nil, form_values: nil)
      @recording.update!(
        metadata: @recording.metadata.merge(
          handoff_state: {
            url: url,
            cookies: cookies,
            local_storage: local_storage,
            session_storage: session_storage,
            form_values: form_values,
            captured_at: Time.current.iso8601
          }
        )
      )
    end

    # Complete the recording
    def complete!
      @recording.complete!
      @recording
    end

    # Mark recording as failed
    def fail!(error_message = nil)
      @recording.fail!(error_message)
      @recording
    end

    # Get the recording timeline for playback
    def timeline
      @recording.timeline
    end

    # Get handoff state for resuming session
    def handoff_state
      @recording.metadata["handoff_state"]
    end

    # Class method: Generate signed URL for stored snapshot
    def self.signed_url_for(storage_key, expires_in: 15.minutes)
      snapshot = RecordingSnapshot.find_by(storage_key: storage_key)
      snapshot&.signed_url(expires_in: expires_in)
    end

    # Class method: Fetch snapshot content
    def self.fetch_snapshot(storage_key)
      snapshot = RecordingSnapshot.find_by(storage_key: storage_key)
      return nil unless snapshot&.file&.attached?

      snapshot.file.download
    rescue StandardError => e
      Rails.logger.error "Failed to fetch snapshot #{storage_key}: #{e.message}"
      nil
    end

    private

    def record_action(action_type:, selector: nil, value: nil, screenshot: nil, dom_snapshot: nil, metadata: {})
      raise RecordingError, "No active recording" unless @recording
      raise RecordingError, "Recording already completed" unless @recording.recording?

      @recording.record_action!(
        action_type: action_type,
        selector: selector,
        value: value,
        screenshot: screenshot,
        dom_snapshot: dom_snapshot,
        metadata: metadata
      )
    end
  end
end
