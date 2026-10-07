# frozen_string_literal: true

module ActionAgent
  class VerifyEvaluationFixJob < ApplicationJob
    queue_as :sandboxes

    def perform(id)
      session = CodeSession.find_by(id: id)
      return unless session&.succeeded? && session.evaluation_run_id && session.diff.present?
      sandbox = session.sandbox_session
      # Hold the checkout lock through the refresh and run creation. Session
      # creation also refuses a verification in progress, so a later edit
      # cannot race the run that is meant to verify this diff.
      sandbox.with_lock do
        session.reload
        return if session.verification_run_id
        raise "No reviewable git diff was captured for this fix" unless session.diff.start_with?("diff --git ")
        raise "The sandbox is no longer running" unless sandbox.ready? && sandbox.active?
        raise "Agent execution is disabled" unless ActionAgent.execution_enabled?
        EvaluationFix.check_scenarios!(session.evaluation_run.evaluation, session.fix_item)
        owner = session.evaluation_run.evaluation.agent.owner
        raise "The sandbox is no longer available to the agent" unless SandboxSession.runtime_server_entry(sandbox.runtime_server_key, owner: owner)
        orchestrator = SandboxOrchestrator.new
        orchestrator.refresh_runtime(sandbox)
        selection = { "sandbox_id" => sandbox.session_id, "keys" => session.fix_item.fetch("scenario_keys"), "models" => session.fix_item.fetch("models") }
        run = session.evaluation_run.evaluation.evaluation_runs.create!(status: :pending, selection: selection)
        session.update!(verification_run: run, verification_error: nil)
        EvaluationRunJob.perform_later(run.evaluation_id, run.id, selection)
      end
    rescue StandardError => error
      session&.update!(verification_error: SecretScrubber.scrub(error.message, session.secrets).truncate(1000))
    end
  end
end
