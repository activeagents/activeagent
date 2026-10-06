# frozen_string_literal: true

module ActionAgent
  module Api
    # The browser of a project's sandbox, for the endpoints that drive it
    # from the engine: an exploration's start and the test account step.
    module ProjectBrowser
      # The tool groups the project's browser starts with: the explorer's
      # locator and verify tools come from "testing".
      CAPABILITIES = %w[testing].freeze

      private

      # The project's ready sandbox, or nil after rendering 409 when it has
      # none.
      def ready_project_sandbox!(project)
        sandbox = project.current_sandbox_session
        return sandbox if sandbox && project.sandbox_state == "ready"

        render json: { error: "Boot the project's sandbox first", code: "sandbox_not_ready", sandbox_state: project.sandbox_state },
          status: :conflict
        nil
      end

      # [sandbox, whether its browser was started now] with the browser
      # running: the one already running, or one started headless with the
      # project's saved sign-in after the host's quota allows
      # :browser_minutes. Nil after rendering why it cannot run.
      def ensure_project_browser!(project, sandbox)
        return [ sandbox, false ] if sandbox.browser_running?

        enforce_quota!(:browser_minutes)
        return nil if performed?

        sandbox, started = SandboxBrowser.ensure_running!(sandbox, capabilities: CAPABILITIES,
          recording_url: ->(recording) { events_api_session_recording_url(recording) },
          storage_state: project.saved_storage_state)
        [ sandbox, started ]
      rescue SandboxBrowser::Error => e
        render json: { error: SecretScrubber.scrub(e.message, project.scrub_values), code: "browser_unavailable" },
          status: :unprocessable_entity
        nil
      end
    end
  end
end
