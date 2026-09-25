# frozen_string_literal: true

module ActionAgent
  class SandboxProvisionJob < ApplicationJob
    MAX_ERROR_MESSAGE = 8_000
    queue_as :sandboxes

    # Provision a Cloud Run sandbox for the session
    # Each sandbox is an instance of the ActiveAgents application running in sandbox mode
    def perform(sandbox_session_id)
      # Deleted before the job ran: nothing to provision. `find` raised here,
      # and the rescue below then called update! on nil.
      sandbox = SandboxSession.find_by(id: sandbox_session_id)
      return if sandbox.nil?

      # SandboxSession#provision! moves a session to provisioning and hands it
      # over exactly once. Any other status means it was provisioned, stopped
      # or has failed since, and provisioning it again would boot a second
      # sandbox for one session (and orphan the first).
      return unless sandbox.provisioning?

      # In development/test, simulate provisioning. A checkout sandbox always
      # goes to a backend: the simulation has no checkout to boot.
      if (Rails.env.development? || Rails.env.test?) && !sandbox.app_runtime?
        simulate_provisioning(sandbox)
        return
      end

      # Hand off to whichever backend this install registered — the engine
      # ships the in-memory one and :local, so a real container/job comes
      # from the host app's backend (see ActionAgent.sandbox_backends).
      ensure_checkout_available!(sandbox) if sandbox.app_runtime?

      orchestrator = SandboxOrchestrator.new
      result = orchestrator.create_sandbox(sandbox)
      # From here on the backend runs a sandbox for this session: whatever
      # goes wrong below, the rescue releases it unless the session recorded
      # its handle.
      handle = result[:sandbox_id]

      # Stopped (or expired) while the backend was booting it: release what
      # was just started rather than reviving the session as ready.
      recorded = mark_ready_unless_stopped(sandbox, result)
      unless recorded
        release(orchestrator, handle)
        return
      end

      # Broadcast status update
      broadcast_sandbox_update(sandbox)
    rescue StandardError => e
      # A backend's error can carry the checkout token (a clone URL, a git
      # error echoing its header) or the Claude Code credential; the message
      # is stored and served to the dashboard, so it is scrubbed first.
      # Kept whole up to a bound (SandboxSession#error_summary shortens it
      # for display, keeping the log tail that names the actual error).
      message = SecretScrubber.scrub(e.message.to_s, secrets_for(sandbox)).truncate(MAX_ERROR_MESSAGE)
      Rails.logger.error("Sandbox provision failed: #{message}")
      # Booted, but the session never recorded the handle (marking it ready
      # raised): nothing else knows the sandbox exists, so nothing would
      # ever terminate it.
      release(orchestrator, handle) if handle && !recorded
      fail_unless_stopped(sandbox, message) if sandbox
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

    # The owner can disconnect GitHub, or drop the repository from their
    # selection, between creating the session and this job running.
    # checkout_spec answers nil for the first and raises ArgumentError for
    # the second; both mean the same thing to the owner.
    def ensure_checkout_available!(sandbox)
      available = begin
        sandbox.checkout_spec.present?
      rescue ArgumentError
        false
      end
      return if available

      raise "#{sandbox.repository} is no longer available: reconnect GitHub or reselect it in Settings -> Integrations"
    end

    # Marks the session ready with the backend's endpoint, under a row lock
    # so a concurrent DELETE either lands first (and this reports false) or
    # finds the session ready with a handle to terminate: SandboxSession#expire!
    # re-reads the row under the same lock rather than trusting the copy it
    # loaded before the boot finished.
    def mark_ready_unless_stopped(sandbox, result)
      sandbox.with_lock do
        next false unless sandbox.provisioning?

        sandbox.mark_ready!(
          cloud_run_url: result[:url],
          cloud_run_job_id: result[:sandbox_id],
          runtime_mcp_url: result[:mcp_url],
          runtime_mcp_token: result[:mcp_token]
        )
        true
      end
    rescue ActiveRecord::RecordNotFound
      false
    end

    def release(orchestrator, handle)
      return if handle.blank?

      orchestrator.terminate(handle)
    rescue StandardError => e
      Rails.logger.warn("Failed to release sandbox #{handle}: #{e.message}")
    end

    # A session stopped while provisioning stays expired: the failure is
    # moot, and marking it failed would bring it back into the owner's list.
    def fail_unless_stopped(sandbox, message)
      sandbox.reload
      return unless sandbox.provisioning?

      sandbox.update!(status: :failed, error_message: message)
      broadcast_sandbox_update(sandbox)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    # What must never reach error_message: the checkout token and the Claude
    # Code credential this session boots with.
    def secrets_for(sandbox)
      return [] if sandbox.nil?

      spec = begin
        sandbox.checkout_spec
      rescue StandardError
        nil
      end
      [ spec&.dig(:token), *sandbox.runtime_environment.values ].compact
    rescue StandardError
      []
    end

    def broadcast_sandbox_update(sandbox)
      ActionCable.server.broadcast(
        "sandbox_#{sandbox.session_id}",
        { type: "status_update", sandbox: sandbox.summary }
      )
    end
  end
end
