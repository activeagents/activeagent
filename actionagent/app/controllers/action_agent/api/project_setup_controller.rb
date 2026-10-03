# frozen_string_literal: true

module ActionAgent
  module Api
    # Getting a project's sandbox to boot and choosing what its App assistant
    # may read:
    #
    #   - starting the setup assistant on a failed boot (see ProjectSetup)
    #   - the requests for input the project's agents are waiting on, which
    #     the Project page answers through the input requests API
    #   - the app's models as a boot listed them, and the models and columns
    #     the App assistant gets schema tools over
    class ProjectSetupController < BaseController
      include ProjectSecretAuthorization

      before_action :require_owner!
      before_action :set_project
      before_action :require_execution_enabled!, only: [ :start ]

      rescue_from Project::ConfirmationRequired, with: :confirmation_required
      rescue_from Project::BootRefused, SandboxOrchestrator::UnsupportedBackendError, with: :boot_refused

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

      # GET /api/projects/:project_id/app_models
      # The app's models and columns as the last boot's manifest listed them,
      # with the choices made so far. 409 before a boot listed any.
      def app_models
        models = @project.app_models
        if models.nil?
          return render json: { error: "Boot the project first: a boot lists the app's models", code: "not_listed" }, status: :conflict
        end

        render json: { models: models, schema_tools: @project.schema_tools }
      end

      # PUT /api/projects/:project_id/schema_tools
      # { schema_tools: [{ model:, filterable: [], returns: [] }], apply: true }
      # Stores the models and columns the App assistant may read. Every boot
      # after this writes their tools; with `apply`, a running sandbox is
      # replaced by a new boot now, so the assistant's tools follow at once.
      def schema_tools
        unless @project.app_assistant?
          return render json: { error: "Only a project evaluated with the App assistant chooses what it may read", code: "not_app_assistant" },
            status: :conflict
        end

        choices = params[:schema_tools]
        unless choices.is_a?(Array) && choices.all? { |choice| choice.respond_to?(:permit) }
          return render json: { error: "schema_tools must be a list of { model:, filterable:, returns: }" }, status: :bad_request
        end

        @project.choose_schema_tools!(choices.map { |choice| choice.permit(:model, filterable: [], returns: []).to_h })
        rebooted = ActiveModel::Type::Boolean.new.cast(params[:apply]) == true && reboot!
        return if performed?

        render json: { project: @project.reload.summary, rebooted: rebooted == true }
      rescue SandboxBootSpec::Invalid => e
        render json: { error: e.message, code: "invalid_schema_tools" }, status: :unprocessable_entity
      end

      private

      def set_project
        @project = owned(Project).find(params[:project_id])
      end

      def secret_subject
        ProjectSecret.new(project: @project, account_id: @project.account_id, user_id: @project.user_id)
      end

      # Stops the current sandbox and boots a new one from the project's
      # spec, as POST /api/projects/:id/boot boots one. Answers whether a
      # boot started.
      def reboot!
        unless ActionAgent.execution_enabled?
          render json: { error: "Agent execution is disabled on this dashboard" }, status: :forbidden
          return false
        end
        enforce_execution_quota!
        return false if performed?

        current = @project.current_sandbox_session
        current.expire! if current && !current.expired?
        @project.ensure_sandbox!(confirm: ActiveModel::Type::Boolean.new.cast(params[:confirm]) == true, confirmed_by: current_user)
        record_execution_usage
        true
      end

      def confirmation_required(exception)
        render json: { error: exception.message, code: "confirmation_required", confirmation: exception.message }, status: :conflict
      end

      def boot_refused(exception)
        render json: { error: exception.message, code: "boot_refused" }, status: :unprocessable_entity
      end
    end
  end
end
