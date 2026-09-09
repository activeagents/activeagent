# frozen_string_literal: true

module ActionAgent
  # Builds the sandbox behind a code session: the backend creates the
  # container, writes the brief into it, and clones the repository if the
  # session was given one.
  #
  # The GitHub token is resolved here rather than at create time, so it is
  # as fresh as possible and never sits in a job argument — job arguments
  # are serialized into the queue, which is a database table.
  class CodeSessionProvisionJob < ApplicationJob
    queue_as :sandboxes

    def perform(code_session_id, run_after = false)
      session = CodeSession.find(code_session_id)
      return unless session.pending?

      session.update!(status: :provisioning, started_at: Time.current, last_activity_at: Time.current)
      session.append_event(kind: "session", label: "Provisioning #{session.tool_name} sandbox", status: "started")

      orchestrator = CodeSessionOrchestrator.new(backend: session.backend)
      result = orchestrator.launch(session, brief: session.brief, github_token: github_token(session))

      session.update!(
        status: :ready,
        container_id: result[:container_id],
        workspace_path: result[:workspace_path],
        last_activity_at: Time.current
      )
      session.append_event(kind: "session", label: "Sandbox ready", detail: result[:container_id])
      broadcast(session)

      CodeSessionRunJob.perform_later(session.id) if run_after
    rescue StandardError => e
      fail_session(session, e)
      raise
    end

    private

    def github_token(session)
      return nil unless session.github_access?

      ActionAgent.github_token_for(session.owner, session)
    end

    def fail_session(session, error)
      return if session.nil?

      # The message can carry backend output, which can carry a token the
      # backend already masks; truncate rather than store a whole log.
      message = error.message.to_s.truncate(1_000)
      session.update!(status: :failed, error_message: message, completed_at: Time.current)
      session.append_event(kind: "session", label: "Provisioning failed", status: "error", detail: message)
      broadcast(session)
    rescue StandardError => e
      Rails.logger.error("[ActionAgent] could not record code session failure: #{e.message}")
    end

    def broadcast(session)
      ActionCable.server.broadcast(
        "code_session_#{session.session_id}",
        { type: "status_update", session: session.as_json_summary }
      )
    rescue StandardError => e
      Rails.logger.debug { "[ActionAgent] code session broadcast skipped: #{e.message}" }
    end
  end
end
