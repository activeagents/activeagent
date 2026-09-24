# frozen_string_literal: true

module ActionAgent
  class SandboxProvisionJob < ApplicationJob
    queue_as :sandboxes

    # Provision a Cloud Run sandbox for the session
    # Each sandbox is an instance of the ActiveAgents application running in sandbox mode
    def perform(sandbox_session_id)
      sandbox = SandboxSession.find(sandbox_session_id)
      return if sandbox.ready? || sandbox.expired?

      # In development/test, simulate provisioning. A checkout sandbox always
      # goes to a backend: the simulation has no checkout to boot.
      if (Rails.env.development? || Rails.env.test?) && !sandbox.app_runtime?
        simulate_provisioning(sandbox)
        return
      end

      # Hand off to whichever backend this install registered — the engine
      # ships only the in-memory one, so a real container/job comes from the
      # host app's backend (see ActionAgent.sandbox_backends).
      if sandbox.app_runtime? && sandbox.checkout_spec.nil?
        raise "#{sandbox.repository} is no longer available: reconnect GitHub or reselect it in Settings -> Integrations"
      end

      result = SandboxOrchestrator.new.create_sandbox(sandbox)

      sandbox.mark_ready!(
        cloud_run_url: result[:url],
        cloud_run_job_id: result[:sandbox_id],
        runtime_mcp_url: result[:mcp_url],
        runtime_mcp_token: result[:mcp_token]
      )

      # Broadcast status update
      broadcast_sandbox_update(sandbox)
    rescue StandardError => e
      Rails.logger.error("Sandbox provision failed: #{e.message}")
      sandbox.update!(status: :failed, error_message: e.message.truncate(500))
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
