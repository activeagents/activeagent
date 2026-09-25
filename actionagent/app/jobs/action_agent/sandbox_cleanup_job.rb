# frozen_string_literal: true

module ActionAgent
  class SandboxCleanupJob < ApplicationJob
    queue_as :sandboxes

    # Release the infrastructure behind an expired sandbox.
    def perform(sandbox_session_id)
      sandbox = SandboxSession.find_by(id: sandbox_session_id)
      return unless sandbox

      Rails.logger.info("Cleaning up sandbox: #{sandbox.session_id}")

      # The handle is kept until the backend confirms it let go: cleared
      # after a failed terminate, nothing would ever know the process (or
      # container) was still there. cleanup_expired! retries these.
      handle = sandbox.cloud_run_job_id.presence || derived_handle(sandbox)
      return if handle.present? && !released?(sandbox, handle)

      # Optionally delete old sandbox records
      # For now, keep for analytics
      sandbox.update!(cloud_run_url: nil, cloud_run_job_id: nil)
    end

    # Periodic cleanup of all expired sandboxes (rake
    # action_agent:sandbox:reap). Expires the sessions past their expiry that
    # are still pending, provisioning, ready or running — each one's
    # resource is released by a job of its own — and returns how many.
    #
    # @return [Integer]
    def self.cleanup_expired!
      # Expired earlier, but their backend failed to terminate them, so they
      # still hold a handle: try again. Collected first, so the sessions
      # expired below are not enqueued twice.
      unreleased = SandboxSession.expired.where.not(cloud_run_job_id: [ nil, "" ]).pluck(:id)

      count = 0
      SandboxSession.expired_sessions.active.find_each do |sandbox|
        sandbox.expire!
        count += 1
      end

      unreleased.each { |id| perform_later(id) }
      count
    end

    private

    # A checkout whose provisioning never recorded a handle (the job died
    # while the backend was booting it) can still hold processes; a backend
    # that can name a session's sandbox without being told answers here.
    def derived_handle(sandbox)
      return nil unless sandbox.app_runtime?

      SandboxOrchestrator.new.handle_for(sandbox)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] could not derive a sandbox handle: #{e.message}")
      nil
    end

    # Whether the backend behind +handle+ let go of it.
    #
    # In development a sandbox other than a checkout was only simulated (see
    # SandboxProvisionJob#simulate_provisioning): no backend holds its
    # made-up handle, so there is nothing to terminate. A checkout is real
    # everywhere — the :local backend runs it as child processes of this
    # app, which skipping terminate in development used to orphan.
    def released?(sandbox, handle)
      return true if Rails.env.development? && !sandbox.app_runtime?

      terminate_backend_sandbox(handle)
    end

    # Through the orchestrator, like provisioning: whichever backend the
    # host registered (Incus, Kubernetes, Cloud Run, the :local one or the
    # built-in mock) reclaims its own resource. This used to require
    # google/cloud/run/v2 directly, which the engine does not depend on — a
    # LoadError is a ScriptError, not a StandardError, so it escaped the
    # rescue and the job failed on every host but the one that happened to
    # bundle the SDK.
    #
    # Backends disagree on what terminate returns; only an explicit false
    # (or an error) counts as not released.
    def terminate_backend_sandbox(sandbox_id)
      SandboxOrchestrator.new.terminate(sandbox_id) != false
    rescue StandardError => e
      Rails.logger.warn("Failed to terminate sandbox #{sandbox_id}: #{e.message}")
      false
    end
  end
end
