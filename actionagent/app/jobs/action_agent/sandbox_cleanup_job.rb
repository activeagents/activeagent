# frozen_string_literal: true

module ActionAgent
  class SandboxCleanupJob < ApplicationJob
    queue_as :sandboxes

    # Release the infrastructure behind an expired sandbox.
    def perform(sandbox_session_id)
      sandbox = SandboxSession.find_by(id: sandbox_session_id)
      return unless sandbox

      Rails.logger.info("Cleaning up sandbox: #{sandbox.session_id}")

      # Terminate the backend resource if one was provisioned
      if sandbox.cloud_run_job_id.present? && !Rails.env.development?
        terminate_backend_sandbox(sandbox.cloud_run_job_id)
      end

      # Optionally delete old sandbox records
      # For now, keep for analytics
      sandbox.update!(cloud_run_url: nil, cloud_run_job_id: nil)
    end

    # Periodic cleanup of all expired sandboxes
    def self.cleanup_expired!
      SandboxSession.expired_sessions.active.find_each do |sandbox|
        sandbox.expire!
      end
    end

    private

    # Through the orchestrator, like provisioning: whichever backend the
    # host registered (Incus, Kubernetes, Cloud Run, or the built-in mock)
    # reclaims its own resource. This used to require google/cloud/run/v2
    # directly, which the engine does not depend on — a LoadError is a
    # ScriptError, not a StandardError, so it escaped the rescue and the job
    # failed on every host but the one that happened to bundle the SDK.
    def terminate_backend_sandbox(sandbox_id)
      SandboxOrchestrator.new.terminate(sandbox_id)
    rescue StandardError => e
      Rails.logger.warn("Failed to terminate sandbox #{sandbox_id}: #{e.message}")
    end
  end
end
