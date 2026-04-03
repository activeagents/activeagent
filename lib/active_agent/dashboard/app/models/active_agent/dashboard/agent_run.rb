# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Tracks individual agent execution runs.
    #
    # Each run captures input, output, timing, token usage, and any errors
    # that occurred during execution.
    #
    # @example Creating a run
    #   run = agent.execute("Analyze this code", code: code)
    #   run.status # => "pending"
    #
    # @example Monitoring a run
    #   run.in_progress? # => true
    #   run.finished?    # => false
    #
    class AgentRun < ApplicationRecord
      belongs_to :agent, class_name: "ActiveAgent::Dashboard::Agent"
      has_one :session_recording, class_name: "ActiveAgent::Dashboard::SessionRecording", dependent: :nullify

      # Status enum
      enum :status, { pending: 0, running: 1, complete: 2, failed: 3, cancelled: 4 }

      # Validations
      validates :trace_id, presence: true

      # Scopes
      scope :recent, -> { order(created_at: :desc) }
      scope :successful, -> { where(status: :complete) }
      scope :failed_runs, -> { where(status: :failed) }
      scope :today, -> { where("created_at >= ?", Time.current.beginning_of_day) }

      # Callbacks
      before_validation :set_trace_id, on: :create
      after_update_commit :broadcast_update, if: :saved_change_to_status?

      # Add a log entry
      def add_log(message, level: :info)
        new_logs = logs || []
        new_logs << {
          timestamp: Time.current.iso8601,
          level: level.to_s,
          message: message
        }
        update!(logs: new_logs)
      end

      # Calculate duration if not set
      def calculated_duration_ms
        return duration_ms if duration_ms.present?
        return nil unless started_at && completed_at

        ((completed_at - started_at) * 1000).to_i
      end

      # Check if run is still in progress
      def in_progress?
        pending? || running?
      end

      # Check if run is finished
      def finished?
        complete? || failed? || cancelled?
      end

      # Get a summary for display
      def summary
        {
          id: id,
          status: status,
          input_preview: input_prompt&.truncate(100),
          output_preview: output&.truncate(200),
          duration_ms: calculated_duration_ms,
          tokens: total_tokens,
          created_at: created_at,
          error: error_message
        }
      end

      # Stream output updates via ActionCable
      def broadcast_update
        return unless defined?(ActionCable)

        ActionCable.server.broadcast(
          "agent_run_#{id}",
          {
            type: "update",
            run: summary
          }
        )
      end

      # Cancel a running execution
      def cancel!
        return unless in_progress?

        update!(
          status: :cancelled,
          completed_at: Time.current,
          error_message: "Cancelled by user"
        )
        broadcast_update
      end

      private

      def set_trace_id
        self.trace_id ||= SecureRandom.uuid
      end
    end
  end
end
