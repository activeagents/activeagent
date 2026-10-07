# frozen_string_literal: true

module ActionAgent
  module Api
    class EvaluationFixesController < BaseController
      before_action :require_owner!

      def index
        evaluation = Evaluation.where(agent: owner_agents).find(params[:evaluation_id])
        run = evaluation.evaluation_runs.find(params[:run_id])
        project = Project.for_evaluation(evaluation)
        scope = owned(SandboxSession)
        scope = scope.where(account_id: current_account.id) if current_account
        sandboxes = project ? scope.where(project_id: project.id, sandbox_type: "app_runtime").recent.limit(20).to_a : []
        sessions = CodeSession.where(evaluation_run_id: run.id, sandbox_session_id: sandboxes.map(&:id)).recent.limit(20)
        render json: {
          project: project && { id: project.id, name: project.name, repository: project.repository },
          sandboxes: sandboxes.map { |sandbox| sandbox.summary.merge(claude_login: ClaudeCodeAuth.sandbox_status(sandbox, user_id: current_user&.id)) },
          code_sessions: sessions.map { |session| session.details(after: session.events.size) },
          auth_mode: ClaudeCodeAuth.mode,
          supported: SandboxOrchestrator.new.supports?(:refresh_runtime),
          refusal: project ? ClaudeCodeAuth.backend_refusal(SandboxOrchestrator.new) : "Link this evaluation to a checkout project before implementing a fix."
        }
      end
    end
  end
end
