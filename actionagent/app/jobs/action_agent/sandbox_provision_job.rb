# frozen_string_literal: true

module ActionAgent
  class SandboxProvisionJob < ApplicationJob
    MAX_ERROR_MESSAGE = 8_000
    queue_as :sandboxes

    # Provision a Cloud Run sandbox for the session
    # Each sandbox is an instance of the ActiveAgents application running in sandbox mode
    #
    # @param options [Hash] for a checkout, at most one of
    #   "boot"   => how to boot it, as SandboxBootSpec.request_options
    #               returns it; without it, "auto"
    #   "resume" => { "from" => a step name or nil }, to continue a failed
    #               boot its backend kept (SandboxSession#resume_boot!)
    def perform(sandbox_session_id, options = {})
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
      options = options.is_a?(Hash) ? options : {}
      # A project's checkout boots from the project's spec, built here so its
      # secrets' values are read in this process and never enqueued.
      project = sandbox.app_runtime? ? sandbox.project : nil
      result =
        if options["resume"].is_a?(Hash)
          orchestrator.resume_boot(sandbox, from: options["resume"]["from"].presence, boot_config: project&.boot_spec)
        elsif project
          orchestrator.create_sandbox(sandbox, boot_config: project.boot_spec)
        elsif (spec = sandbox.app_runtime? && boot_spec(options["boot"]))
          orchestrator.create_sandbox(sandbox, boot_config: spec)
        else
          orchestrator.create_sandbox(sandbox)
        end
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

      project&.sandbox_ready!(sandbox)
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

    # The boot spec a checkout's boot options ask for, or nil to boot it as
    # its sandbox.yml says. A spec "auto" asked for that cannot be built
    # (the engine's gems come from a git URL with credentials in it) is
    # dropped with a warning, so a checkout that bundles the engine still
    # boots. One asked for with "always" fails the boot with the reason.
    def boot_spec(boot)
      boot = boot.is_a?(Hash) ? boot : {}
      SandboxBootSpec.for_request(boot)
    rescue SandboxBootSpec::Invalid => e
      raise "Sandbox boot spec is invalid: #{e.message}" if %w[always true].include?(boot["bootstrap"].to_s)

      Rails.logger.warn("[ActionAgent] not bootstrapping checkouts without the engine: #{e.message}")
      nil
    end

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
      sandbox.project&.sandbox_failed!(sandbox)
      broadcast_sandbox_update(sandbox)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    # What must never reach error_message: the checkout token, the Claude
    # Code credential this session boots with, and its project's secrets.
    def secrets_for(sandbox)
      return [] if sandbox.nil?

      spec = begin
        sandbox.checkout_spec
      rescue StandardError
        nil
      end
      [ spec&.dig(:token), *sandbox.runtime_environment.values, *sandbox.project_scrub_values ].compact
    rescue StandardError
      []
    end

    def broadcast_sandbox_update(sandbox)
      LiveUpdates.broadcast("sandbox_#{sandbox.session_id}", type: "status_update", id: sandbox.session_id, status: sandbox.status)
    end
  end
end
