# frozen_string_literal: true

module ActionAgent
  class SandboxProvisionJob < ApplicationJob
    queue_as :sandboxes

    # Provision a Cloud Run sandbox for the session
    # Each sandbox is an instance of the ActiveAgents application running in sandbox mode
    def perform(sandbox_session_id)
      sandbox = SandboxSession.find(sandbox_session_id)
      return if sandbox.ready? || sandbox.expired?

      # In development/test, simulate provisioning
      if Rails.env.development? || Rails.env.test?
        simulate_provisioning(sandbox)
        return
      end

      # Hand off to whichever backend this install registered — the engine
      # ships only the in-memory one, so a real container/job comes from the
      # host app's backend (see ActionAgent.sandbox_backends).
      result = SandboxOrchestrator.new.create_sandbox(sandbox)

      sandbox.mark_ready!(
        cloud_run_url: result[:url],
        cloud_run_job_id: result[:sandbox_id]
      )

      # Broadcast status update
      broadcast_sandbox_update(sandbox)
    rescue StandardError => e
      Rails.logger.error("Sandbox provision failed: #{e.message}")
      sandbox.update!(status: :failed)
      broadcast_sandbox_update(sandbox)
    end

    private

    def simulate_provisioning(sandbox)
      # Simulate a small delay for provisioning
      sleep(0.5)

      sandbox.mark_ready!(
        cloud_run_url: "http://localhost:3000/api/sandbox",
        cloud_run_job_id: "local-#{sandbox.session_id[0..7]}"
      )
    end

    def broadcast_sandbox_update(sandbox)
      ActionCable.server.broadcast(
        "sandbox_#{sandbox.session_id}",
        { type: "status_update", sandbox: sandbox.summary }
      )
    end
  end
end
