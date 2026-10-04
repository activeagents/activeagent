# frozen_string_literal: true

module ActionAgent
  module Api
    # The test account step: how the project's browser signs in to the app,
    # kept as sign-in ProjectSecrets that never reach the sandbox's
    # environment or a model.
    #
    #   GET    /api/projects/:project_id/sign_in               what is set, never the password
    #   PUT    /api/projects/:project_id/sign_in               { login_url, login, password,
    #                                                            login_field, password_field, submit_field }
    #   POST   /api/projects/:project_id/sign_in/check         signs the browser in with them
    #   POST   /api/projects/:project_id/sign_in/save_browser  keeps the running browser's sign-in
    #   DELETE /api/projects/:project_id/sign_in               no sign-in
    #
    # Changing them needs :manage_project_secrets, asked about the secret.
    # A check answers BrowserSignIn's status, "unsupported" when the login
    # page has no password field.
    class ProjectSignInsController < BaseController
      include ProjectBrowser

      before_action :require_owner!
      before_action :set_project
      before_action :require_execution_enabled!, only: [ :check ]

      def show
        render json: { sign_in: summary }
      end

      def update
        secret = @project.assign_sign_in(credential_params, set_by: current_user)
        return unless authorize_action!(:manage_project_secrets, secret)

        if secret.save
          render json: { sign_in: summary, warnings: secret.warnings }
        else
          render json: { error: secret.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end
      end

      def destroy
        secrets = @project.secrets.where(kind: %w[sign_in storage_state]).to_a
        return unless secrets.all? { |secret| authorize_action!(:manage_project_secrets, secret) }

        secrets.each(&:destroy!)
        render json: { sign_in: summary }
      end

      def check
        secret = @project.secrets.sign_in.find_by(name: Project::SIGN_IN_SECRET)
        unless secret
          return render json: { error: "Enter the test account's login and password first", code: "no_sign_in" },
            status: :unprocessable_entity
        end

        sandbox = ready_project_sandbox!(@project) or return
        sandbox, = ensure_project_browser!(@project, sandbox)
        return if performed?

        render json: { result: BrowserSignIn.call(sandbox, secret).to_h, sign_in: summary }
      end

      def save_browser
        sandbox = @project.current_sandbox_session
        unless sandbox&.browser_running?
          return render json: { error: "Start the project's browser and sign in to the app there first", code: "browser_not_running" },
            status: :conflict
        end

        state = SandboxBrowser.storage_state(sandbox)
        secret = @project.assign_storage_state(state, set_by: current_user)
        return unless authorize_action!(:manage_project_secrets, secret)

        if secret.save
          render json: { sign_in: summary }
        else
          render json: { error: secret.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end
      rescue SandboxBrowser::Error => e
        render json: { error: e.message, code: "browser_unavailable" }, status: :unprocessable_entity
      end

      private

      def set_project
        @project = owned(Project).find(params[:project_id])
      end

      def credential_params
        params.permit(*ProjectSecret::SIGN_IN_FIELDS).to_h
      end

      def summary
        credentials = @project.secrets.sign_in.find_by(name: Project::SIGN_IN_SECRET)
        state = @project.secrets.storage_state.find_by(name: Project::STORAGE_STATE_SECRET)
        fields = credentials&.sign_in_credentials || {}
        {
          credentials: credentials && {
            secret_ref: credentials.name,
            login_url: fields["login_url"],
            login: fields["login"],
            password_set: fields["password"].present?,
            fields: fields.slice("login_field", "password_field", "submit_field"),
            updated_at: credentials.updated_at&.iso8601
          },
          storage_state: state && { saved: true, updated_at: state.updated_at&.iso8601 },
          browser_running: @project.current_sandbox_session&.browser_running? || false
        }
      end
    end
  end
end
