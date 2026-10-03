# frozen_string_literal: true

module ActionAgent
  module Api
    # Getting a project's sandbox to boot:
    #
    #   - starting the setup assistant on a failed boot (see ProjectSetup)
    #   - the requests for input the project's agents are waiting on, which
    #     the Project page answers through the input requests API
    class ProjectSetupController < BaseController
      include ProjectSecretAuthorization

      before_action :require_owner!
      before_action :set_project
      before_action :require_execution_enabled!, only: [ :start ]

      # POST /api/projects/:project_id/setup
      # Starts the setup assistant on the project's failed boot. Its tools
      # set the project's environment, so this needs :manage_project_secrets.
      def start
        return unless authorize_action!(:manage_project_secrets, secret_subject)

        enforce_execution_quota!
        return if performed?

        run = ProjectSetup.start!(@project, trigger: "requested")
        record_execution_usage
        render json: { project: @project.reload.summary, run: { id: run.id, status: run.status, agent_id: run.agent_id } },
          status: :accepted
      rescue ProjectSetup::Unavailable => e
        render json: { error: e.message, code: "setup_unavailable" }, status: :conflict
      end

      # PATCH /api/projects/:project_id/setup { auto: false }
      # Whether a failed boot starts the setup assistant on its own.
      def update
        return unless authorize_action!(:manage_project_secrets, secret_subject)

        @project.update_setup_settings!("auto" => ActiveModel::Type::Boolean.new.cast(params[:auto]) != false)
        render json: { project: @project.summary }
      end

      # GET /api/projects/:project_id/input_requests
      # The requests pending on runs of the project's setup assistant and of
      # the agent it evaluates, newest first, as GET /api/input_requests
      # lists them. Overdue ones are expired first.
      def input_requests
        InputRequest.expire_overdue!(@project.input_requests)
        requests = @project.pending_input_requests.for_listing.includes(:subject).recent.limit(InputRequestsController::LIST_LIMIT)
        render json: { input_requests: requests.map { |request| InputRequestSerializer.call(request) } }
      end

      private

      def set_project
        @project = owned(Project).find(params[:project_id])
      end

      def secret_subject
        ProjectSecret.new(project: @project, account_id: @project.account_id, user_id: @project.user_id)
      end
    end
  end
end
