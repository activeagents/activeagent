# frozen_string_literal: true

module ActionAgent
  module Api
    # Starts the engine's explorer on a project:
    #
    #   POST /api/projects/:project_id/explorations { budget: { minutes:, steps:, cost: } }
    #
    # The host's quota is asked about :exploration first, and a denial
    # answers 402 with nothing started. Otherwise the project's ready
    # sandbox gets a browser (started headless with the project's saved
    # sign-in when none runs, which the quota is asked about as
    # :browser_minutes), the explorer's run and the exploration are created,
    # :exploration usage is recorded once, and ExplorationJob walks the app.
    # An explorer exploration of the project that is still walking answers
    # 409. The budget defaults to Exploration::DEFAULT_BUDGET.
    class ProjectExplorationsController < BaseController
      include ProjectBrowser

      before_action :require_owner!
      before_action :require_execution_enabled!
      before_action :set_project

      rescue_from Exploration::InvalidCandidate, with: :invalid_budget

      def create
        budget = Exploration.budget_from(params[:budget])
        enforce_quota!(:exploration)
        return if performed?

        unless @project.target_agent
          return render json: { error: "Choose the agent to evaluate first", code: "no_target" }, status: :conflict
        end
        if Exploration.where(project_id: @project.id, source: "explorer", status: %w[pending running]).exists?
          return render json: { error: "An exploration of this project is already running", code: "exploration_running" },
            status: :conflict
        end

        sandbox = ready_project_sandbox!(@project) or return
        sandbox, started = ensure_project_browser!(@project, sandbox)
        return if performed?

        exploration = create_exploration!(sandbox, budget)
        ActionAgent.record_usage(current_owner, :exploration)
        ExplorationJob.perform_later(exploration.id, started)

        render json: { exploration: exploration.summary }, status: :created
      end

      private

      def set_project
        @project = owned(Project).find(params[:project_id])
      end

      def create_exploration!(sandbox, budget)
        agent = @project.explorer_agent!
        Exploration.transaction do
          run = agent.agent_runs.create!(
            input_prompt: "Explore #{@project.repository}, starting at #{@project.start_url}.",
            input_params: AgentRun.params_with_actor({}, current_user).merge(
              AgentRun::SANDBOX_PARAM => sandbox.runtime_server_key, AgentRun::BROWSER_PARAM => sandbox.browser_server_key
            ),
            trace_id: SecureRandom.uuid,
            status: :pending
          )
          exploration = Exploration.build_for(project: @project, source: "explorer", status: "pending", budget: budget)
          exploration.assign_attributes(agent_run: run, sandbox_session: sandbox,
            session_recording: SessionRecording.recording.where(sandbox_session_id: sandbox.id).order(:id).last)
          exploration.save!
          exploration
        end
      end

      def invalid_budget(exception)
        render json: { error: exception.message }, status: :unprocessable_entity
      end
    end
  end
end
