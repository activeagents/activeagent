# frozen_string_literal: true

module ActionAgent
  # SandboxRun tracks individual agent task executions within a sandbox container.
  # This model uses SQLite in sandbox mode for isolated, ephemeral storage.
  class SandboxRun < ApplicationRecord
    enum :status, {
      pending: 0,
      running: 1,
      completed: 2,
      failed: 3,
      cancelled: 4
    }

    validates :task, presence: true
    validates :status, presence: true

    scope :recent, -> { order(created_at: :desc) }
    scope :completed_runs, -> { where(status: [ :completed, :failed ]) }

    # Summary for API responses
    def summary
      {
        id: id,
        task: task.truncate(100),
        status: status,
        duration_ms: duration_ms,
        tokens_used: tokens_used,
        created_at: created_at&.iso8601,
        completed_at: completed_at&.iso8601
      }
    end

    # Detailed info including full result
    def details
      summary.merge(
        task: task,
        result: result,
        error: error,
        screenshots: screenshots || [],
        started_at: started_at&.iso8601
      )
    end
  end
end
