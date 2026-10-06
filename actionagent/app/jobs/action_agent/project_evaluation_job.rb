# frozen_string_literal: true

module ActionAgent
  # Runs a project's evaluation (Api::ProjectsController#run_evaluation)
  # against the project's sandbox once it serves. The run was created
  # pending; while the sandbox boots, the job checks again every
  # POLL_INTERVAL rather than holding a worker, and fails the run when the
  # boot fails, stops, or takes longer than BOOT_WAIT.
  #
  # Every replay also reaches the sandbox's browser (see
  # ScenarioEvaluationRunner), whose recording posts to the dashboard
  # mounted at +mount_url+ when the run starts it.
  class ProjectEvaluationJob < ApplicationJob
    queue_as :agents

    POLL_INTERVAL = 10.seconds
    BOOT_WAIT = 1.hour

    def perform(project_id, run_id, mount_url = nil)
      run = EvaluationRun.find_by(id: run_id)
      return unless run&.pending?

      project = Project.find_by(id: project_id)
      return fail_run(run, "The project was deleted before the run started") if project.nil?

      sandbox = project.current_sandbox_session
      case project.sandbox_state
      when "ready"
        start(run, sandbox, mount_url)
      when "booting"
        if run.created_at <= BOOT_WAIT.ago
          fail_run(run, "The project's sandbox did not finish booting within #{BOOT_WAIT.inspect}")
        else
          self.class.set(wait: POLL_INTERVAL).perform_later(project_id, run_id, mount_url)
        end
      when "failed"
        reason = SecretScrubber.scrub(sandbox.error_message.to_s.lines.first.to_s.strip, project.scrub_values)
        fail_run(run, "The project's sandbox failed to boot#{": #{reason}" if reason.present?}")
      else
        fail_run(run, "The project's sandbox stopped before the run started: run the evaluation again")
      end
    end

    private

    def start(run, sandbox, mount_url)
      evaluation = run.evaluation
      if ActionAgent.scenario_evaluation_adapter_resolver&.call(evaluation).respond_to?(:call)
        return fail_run(run, "This install replays scenarios through its own adapter, which cannot reach a project's sandbox")
      end

      evaluation.run!(run: run, sandbox_id: sandbox.session_id, browser: true, mount_url: mount_url)
    end

    def fail_run(run, message)
      run.update!(status: :failed, error_message: message, completed_at: Time.current)
    end
  end
end
