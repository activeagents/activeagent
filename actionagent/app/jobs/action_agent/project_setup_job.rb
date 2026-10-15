# frozen_string_literal: true

module ActionAgent
  # Starts help for a project once a boot of the project failed: a Claude
  # Code session in the failed checkout when the owner's Claude Code is
  # connected (see ProjectBootFix.after_boot_failed), and the setup assistant
  # otherwise (see ProjectSetup.after_boot_failed). Takes ids only; a project or
  # sandbox deleted since, or a sandbox that is no longer the project's
  # current one, starts nothing.
  class ProjectSetupJob < ApplicationJob
    queue_as :agents

    def perform(project_id, sandbox_session_id)
      project = Project.find_by(id: project_id)
      sandbox = SandboxSession.find_by(id: sandbox_session_id)
      return if project.nil? || sandbox.nil? || !sandbox.failed?

      ProjectBootFix.after_boot_failed(project, sandbox) || ProjectSetup.after_boot_failed(project, sandbox)
    end
  end
end
