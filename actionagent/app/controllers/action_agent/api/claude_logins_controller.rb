# frozen_string_literal: true

module ActionAgent
  module Api
    class ClaudeLoginsController < BaseController
      before_action :require_owner!
      before_action :require_execution_enabled!
      before_action :set_sandbox

      def show
        @sandbox.with_lock do
          return render json: { login: { status: "disconnected", logged_in: false, auth_method: nil } } unless mine?
          render json: { login: orchestrator.claude_login_status(@sandbox) }
        end
      end

      def create
        login = nil
        @sandbox.with_lock do
          unless @sandbox.claude_login_user_id.nil? || mine?
            return render json: { error: "This sandbox has another member's login. Start your own sandbox or use the account API key." }, status: :conflict
          end
          return busy if @sandbox.code_sessions.where(status: [ :queued, :running ]).exists?
          login = orchestrator.start_claude_login(@sandbox)
          @sandbox.update!(claude_login_user_id: current_user.id)
        end
        render json: { login: login }, status: :accepted
      end

      def code
        # Filtered by engine.filter_parameters. Never interpolate this value
        # into an error, an event, a model, or a log line.
        login = nil
        @sandbox.with_lock do
          return forbidden unless mine?
          login = orchestrator.submit_claude_login_code(@sandbox, params[:claude_login_code])
        end
        render json: { login: login }
      end

      def destroy
        @sandbox.with_lock do
          return forbidden unless mine?
          return busy if @sandbox.code_sessions.where(status: [ :queued, :running ]).exists?
          orchestrator.claude_logout(@sandbox)
          @sandbox.update!(claude_login_user_id: nil)
        end
        render json: { login: { status: "disconnected", logged_in: false, auth_method: nil } }
      end

      rescue_from LocalSandboxBackend::Error, SandboxOrchestrator::UnsupportedBackendError do
        # Backend errors may include command output; login endpoints expose
        # a fixed message, never raw exception text.
        render json: { error: "Claude sign-in could not complete. Check that Claude Code is installed, then start again." }, status: :unprocessable_entity
      end

      private

      def set_sandbox
        scope = owned(SandboxSession)
        scope = scope.where(account_id: current_account.id) if current_account
        @sandbox = scope.find_by!(session_id: params[:sandbox_id])
        unless ClaudeCodeAuth.sandbox_login? && current_user.respond_to?(:id) && current_user.id.present?
          return render json: { error: "Sandbox subscription login requires a signed-in user and :sandbox_login mode" }, status: :unprocessable_entity
        end
        if (refusal = ClaudeCodeAuth.backend_refusal(orchestrator))
          return render json: { error: refusal }, status: :unprocessable_entity
        end
        unless @sandbox.app_runtime? && @sandbox.ready? && @sandbox.active?
          render json: { error: "Sign in after this checkout sandbox is ready" }, status: :unprocessable_entity
        end
        response.headers["Cache-Control"] = "no-store"
      end

      def mine? = @sandbox.claude_login_user_id == current_user.id
      def orchestrator = @orchestrator ||= SandboxOrchestrator.new
      def forbidden = render(json: { error: "This login belongs to another user" }, status: :forbidden)
      def busy = render(json: { error: "Wait for the running code session before changing its login" }, status: :conflict)
    end
  end
end
