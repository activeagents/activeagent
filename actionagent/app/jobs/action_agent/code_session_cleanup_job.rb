# frozen_string_literal: true

module ActionAgent
  # Releases the sandbox behind a code session: the container, and with it
  # the GitHub token and provider credential the backend wrote to disk for
  # the session's lifetime.
  #
  # The row stays. A finished session is a record of what a coding agent was
  # told and what it did, which is worth keeping; the compute and the
  # secrets are not.
  class CodeSessionCleanupJob < ApplicationJob
    queue_as :sandboxes

    def perform(code_session_id)
      session = CodeSession.find_by(id: code_session_id)
      return unless session

      terminated = CodeSessionOrchestrator.new(backend: session.backend).terminate(session)
      session.append_event(
        kind: "session",
        label: terminated ? "Sandbox released" : "Sandbox could not be released",
        status: terminated ? "done" : "error"
      )
      session.update!(container_id: nil, workspace_path: nil) if terminated
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] code session cleanup failed: #{e.message}")
    end

    # Reclaims sandboxes that outlived their window. Called from a scheduler
    # the host app owns, the way SandboxCleanupJob.cleanup_expired! is.
    def self.expire_stale!
      CodeSession.active.expired_sessions.find_each do |session|
        session.update!(status: :expired, completed_at: session.completed_at || Time.current)
        perform_later(session.id)
      end
    end
  end
end
