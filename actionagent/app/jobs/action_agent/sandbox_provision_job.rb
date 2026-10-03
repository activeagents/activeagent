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
      if sandbox.app_runtime?
        ensure_checkout_available!(sandbox)
        mint_checkout_token!(sandbox)
      end

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
        release(orchestrator, handle, sandbox.id)
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
      release(orchestrator, handle, sandbox.id) if handle && !recorded
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
    # A GitHub App installation can also have been unlinked, or found removed
    # or suspended by an earlier mint.
    def ensure_checkout_available!(sandbox)
      installation = sandbox.checkout_installation
      raise reinstall_message(sandbox, installation.removed_at ? :removed : :suspended) if installation && !installation.usable?

      available = begin
        sandbox.checkout_spec.present?
      rescue ArgumentError
        false
      end
      return if available

      raise "#{sandbox.repository} is no longer available: reconnect GitHub or reselect it in Settings -> Integrations"
    end

    # The one mint of a provision (see SandboxSession#mint_checkout_spec!).
    # The token stays on +sandbox+, the object the orchestrator hands the
    # backend and #secrets_for reads, so the backend clones with exactly the
    # value this job scrubs.
    def mint_checkout_token!(sandbox)
      sandbox.mint_checkout_spec!
    rescue GithubClient::InstallationUnavailable => e
      raise reinstall_message(sandbox, e.reason)
    rescue GithubClient::Error => e
      raise "Could not get a GitHub token to check out #{sandbox.repository}: #{e.message}"
    end

    def reinstall_message(sandbox, reason)
      installation = sandbox.checkout_installation
      on = installation ? " on #{installation.github_account_login}" : ""
      if reason == :suspended
        "The GitHub App installation#{on} is suspended, so #{sandbox.repository} cannot be checked out. " \
          "Once it is unsuspended on GitHub, use Check again in Settings -> Integrations and start the sandbox again."
      else
        "The GitHub App installation#{on} was removed, so #{sandbox.repository} cannot be checked out. " \
          "Reinstall the GitHub App in Settings -> Integrations and start the sandbox again."
      end
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

    def release(orchestrator, handle, sandbox_id)
      return if handle.blank?

      released = orchestrator.terminate(handle)
      keep_handle(sandbox_id, handle) if released == false
    rescue StandardError => e
      Rails.logger.warn("Failed to release sandbox #{handle}: #{e.message}")
      keep_handle(sandbox_id, handle)
    end

    # The backend could not release it now: record the handle on the
    # (expired) session so the reaper retries, as SandboxCleanupJob does.
    def keep_handle(sandbox_id, handle)
      SandboxSession.where(id: sandbox_id).update_all(cloud_run_job_id: handle)
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
    # Code credential this session boots with. Reads the checkout without
    # minting, so a GitHub App checkout contributes the token this job minted.
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
      LiveUpdates.broadcast("sandbox_#{sandbox.session_id}", type: "status_update", id: sandbox.session_id, status: sandbox.status)
    end
  end
end
