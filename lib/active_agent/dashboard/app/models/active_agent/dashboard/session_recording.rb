# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Records browser sessions for playback and analysis.
    #
    # Session recordings capture the sequence of actions taken during
    # an agent run or sandbox session, including screenshots, DOM snapshots,
    # and timing information.
    #
    # @example Starting a recording
    #   recording = ActiveAgent::Dashboard::SessionRecording.start!(
    #     agent_run: run,
    #     name: "checkout_flow"
    #   )
    #
    # @example Recording an action
    #   recording.record_action!(
    #     action_type: "click",
    #     selector: "button.submit",
    #     screenshot: screenshot_data
    #   )
    #
    class SessionRecording < ApplicationRecord
      belongs_to :agent_run, class_name: "ActiveAgent::Dashboard::AgentRun", optional: true
      belongs_to :sandbox_session, class_name: "ActiveAgent::Dashboard::SandboxSession", optional: true

      has_many :recording_actions, class_name: "ActiveAgent::Dashboard::RecordingAction", dependent: :destroy
      has_many :recording_snapshots, class_name: "ActiveAgent::Dashboard::RecordingSnapshot", dependent: :destroy

      enum :status, { recording: 0, completed: 1, failed: 2 }

      validates :status, presence: true
      validate :must_have_parent, unless: -> { demo_recording? || user_session? }

      scope :recent, -> { order(created_at: :desc) }
      scope :for_agent, ->(agent_id) { joins(:agent_run).where(agent_runs: { agent_id: agent_id }) }
      scope :demo, -> { where(name: "lander_demo") }
      scope :user_sessions, -> { where("name LIKE ?", "user_takeover_%") }

      # Check if this is a demo recording (doesn't require parent)
      def demo_recording?
        name&.start_with?("lander_") || name == "demo"
      end

      # Check if this is a user takeover session (doesn't require parent)
      def user_session?
        name&.start_with?("user_takeover_")
      end

      # Start a new recording session
      def self.start!(agent_run: nil, sandbox_session: nil, name: nil)
        create!(
          agent_run: agent_run,
          sandbox_session: sandbox_session,
          name: name || generate_name(agent_run, sandbox_session),
          status: :recording,
          metadata: { started_at: Time.current.iso8601 }
        )
      end

      # Start a user takeover session (for lander demo analytics)
      def self.start_user_session!(visitor_id: nil, parent_demo_id: nil, page_url: nil)
        create!(
          name: "user_takeover_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(4)}",
          status: :recording,
          metadata: {
            started_at: Time.current.iso8601,
            session_type: "user_takeover",
            visitor_id: visitor_id,
            parent_demo_id: parent_demo_id,
            page_url: page_url,
            user_agent: nil
          }
        )
      end

      # Record a browser action
      def record_action!(action_type:, selector: nil, value: nil, screenshot: nil, dom_snapshot: nil, metadata: {})
        raise "Recording already completed" unless recording?

        action = recording_actions.create!(
          action_type: action_type,
          sequence: next_sequence,
          timestamp_ms: elapsed_ms,
          selector: selector,
          value: value,
          metadata: metadata
        )

        if screenshot.present?
          snapshot = store_snapshot(screenshot, :screenshot, action)
          action.update!(screenshot_key: snapshot.storage_key)
        end

        if dom_snapshot.present?
          snapshot = store_snapshot(dom_snapshot, :dom, action)
          action.update!(dom_snapshot_key: snapshot.storage_key)
        end

        increment!(:action_count)
        action
      end

      # Complete the recording
      def complete!
        return unless recording?

        update!(
          status: :completed,
          duration_ms: elapsed_ms,
          metadata: metadata.merge(completed_at: Time.current.iso8601)
        )
      end

      # Mark recording as failed
      def fail!(error_message = nil)
        return unless recording?

        update!(
          status: :failed,
          duration_ms: elapsed_ms,
          metadata: metadata.merge(
            failed_at: Time.current.iso8601,
            error: error_message
          )
        )
      end

      # Get timeline data for playback
      def timeline
        recording_actions.order(:sequence).map do |action|
          {
            id: action.id,
            type: action.action_type,
            sequence: action.sequence,
            timestamp_ms: action.timestamp_ms,
            selector: action.selector,
            value: action.value,
            screenshot_key: action.screenshot_key,
            metadata: action.metadata
          }
        end
      end

      private

      def must_have_parent
        return if agent_run.present? || sandbox_session.present?

        errors.add(:base, "must belong to an agent_run or sandbox_session")
      end

      def self.generate_name(agent_run, sandbox_session)
        prefix = if agent_run&.agent
          agent_run.agent.name.parameterize
        elsif sandbox_session&.agent_template
          sandbox_session.agent_template.name.parameterize
        else
          "session"
        end

        "#{prefix}_#{Time.current.strftime('%Y%m%d_%H%M%S')}"
      end

      def next_sequence
        (recording_actions.maximum(:sequence) || 0) + 1
      end

      def elapsed_ms
        ((Time.current - created_at) * 1000).to_i
      end

      def store_snapshot(data, snapshot_type, action = nil)
        storage_key = generate_storage_key(snapshot_type, action&.sequence)

        recording_snapshots.create!(
          recording_action: action,
          storage_key: storage_key,
          snapshot_type: snapshot_type,
          file_size_bytes: data.bytesize
        )
      end

      def generate_storage_key(snapshot_type, sequence = nil)
        parts = [ "recordings", id, snapshot_type.to_s ]
        parts << sequence.to_s if sequence
        parts << SecureRandom.hex(8)
        parts.join("/")
      end
    end
  end
end
