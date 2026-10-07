# frozen_string_literal: true

module ActionAgent
  class VerifyEvaluationFixJob < ApplicationJob
    queue_as :sandboxes

    def perform(id)
      session = CodeSession.find_by(id: id)
      return unless session&.succeeded? && session.evaluation_run_id && session.diff.present?
      sandbox = session.sandbox_session
      run = nil
      # Claim the verification under the checkout's lock: the pending run is
      # what CodeSessionsController#busy_session waits on, so no later edit
      # can race it. The restart happens after the lock is released, since
      # it takes as long as a boot and the lock is a database row lock.
      sandbox.with_lock do
        session.reload
        return if session.verification_run_id
        raise "No reviewable git diff was captured for this fix" unless session.diff.start_with?("diff --git ")
        raise "The sandbox is no longer running" unless sandbox.ready? && sandbox.active?
        raise "Agent execution is disabled" unless ActionAgent.execution_enabled?
        EvaluationFix.check_scenarios!(session.evaluation_run.evaluation, session.fix_item)
        owner = session.evaluation_run.evaluation.agent.owner
        raise "The sandbox is no longer available to the agent" unless SandboxSession.runtime_server_entry(sandbox.runtime_server_key, owner: owner)
        selection = { "sandbox_id" => sandbox.session_id, "keys" => session.fix_item.fetch("scenario_keys"), "models" => session.fix_item.fetch("models") }
        run = session.evaluation_run.evaluation.evaluation_runs.create!(status: :pending, selection: selection)
        session.update!(verification_run: run, verification_error: nil)
      end
      SandboxOrchestrator.new.refresh_runtime(sandbox)
      EvaluationRunJob.perform_later(run.evaluation_id, run.id, run.selection)
    rescue StandardError => error
      message = SecretScrubber.scrub(error.message, session&.secrets).truncate(1000)
      run&.update!(status: :failed, error_message: message, completed_at: Time.current)
      session&.update!(verification_error: message)
    end
  end
end
