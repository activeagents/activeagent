# frozen_string_literal: true

module ActionAgent
  module Api
    # Headless Claude Code sessions inside one of the caller's checkout
    # sandboxes (Settings -> Integrations): start one with a prompt, poll its
    # transcript, cancel it.
    #
    # A session runs with the owner's connected Claude Code credential and
    # edits the checkout, so starting one is execution — gated, and counted
    # against the host app's quota, like running an agent.
    class CodeSessionsController < BaseController
      before_action :require_owner!
      before_action :require_execution_enabled!, only: [ :create ]
      before_action :set_sandbox
      before_action :set_code_session, only: [ :show, :cancel ]

      # A model name as Claude Code's --model takes it ("sonnet",
      # "claude-sonnet-4-5", "claude-sonnet-4-5[1m]"). It becomes an argument
      # to the CLI, so nothing that could read as another option gets there.
      MODEL_NAME = /\A[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,99}\z/

      # GET /api/sandboxes/:sandbox_id/code_sessions
      def index
        render json: { code_sessions: @sandbox.code_sessions.recent.limit(20).map(&:summary) }
      end

      # POST /api/sandboxes/:sandbox_id/code_sessions
      def create
        if (refusal = refusal_for(@sandbox))
          return render json: { error: refusal }, status: :unprocessable_entity
        end

        if (current = busy_session)
          return render json: busy_body(current), status: :conflict
        end

        code_session = CodeSession.new(
          sandbox_session: @sandbox,
          prompt: string_param(:prompt),
          model: string_param(:model).presence,
          # Owned like the sandbox it runs in.
          user_id: @sandbox.try(:user_id),
          account_id: @sandbox.try(:account_id)
        )
        if (error = invalid_request(code_session))
          return render json: { error: error }, status: :unprocessable_entity
        end

        enforce_execution_quota!
        return if performed?

        # Checked again under the sandbox's row lock, so two requests racing
        # past the check above cannot both start a session in one checkout.
        current = nil
        @sandbox.with_lock do
          current = busy_session
          code_session.save! unless current
        end
        return render json: busy_body(current), status: :conflict if current

        record_execution_usage
        CodeSessionJob.perform_later(code_session.id)

        render json: { code_session: code_session.summary }, status: :created
      end

      # GET /api/sandboxes/:sandbox_id/code_sessions/:id?after=N
      # The transcript from event N onward, for incremental polling.
      def show
        render json: { code_session: @code_session.details(after: integer_param(:after, default: 0)) }
      end

      # POST /api/sandboxes/:sandbox_id/code_sessions/:id/cancel
      def cancel
        was_running = false
        @code_session.with_lock do
          next unless @code_session.queued? || @code_session.running?

          was_running = @code_session.running?
          # A queued session is settled at once: nothing will ever run it. A
          # running one is settled by CodeSessionJob once its Claude Code has
          # stopped and its diff was taken (see CodeSession#diff_pending?).
          @code_session.update!(status: :cancelled, finished_at: was_running ? nil : Time.current)
        end

        # A queued session never started: CodeSessionJob skips it. A running
        # one is stopped by its backend; CodeSessionJob then finds it
        # cancelled and leaves it so.
        stop(@code_session) if was_running

        render json: { code_session: @code_session.summary }
      end

      private

      # A checkout runs on its account's GitHub token and Claude Code
      # credential, so in a multi-tenant install it must belong to the
      # caller's current account too — not only to the caller, who may have
      # left that account or switched to another.
      def set_sandbox
        scope = owned(SandboxSession)
        scope = scope.where(account_id: current_account.id) if current_account
        @sandbox = scope.find_by!(session_id: params[:sandbox_id])
      end

      def set_code_session
        @code_session = @sandbox.code_sessions.find(params[:id])
      end

      # Why +sandbox+ cannot take a Claude Code session now, or nil.
      def refusal_for(sandbox)
        return "Claude Code sessions run only in a checkout (app_runtime) sandbox" unless sandbox.app_runtime?
        return "The sandbox has expired; start a new one" if sandbox.ready? && !sandbox.active?
        return "The sandbox is #{sandbox.status}; wait until it is ready" unless sandbox.ready?

        orchestrator = SandboxOrchestrator.new
        unless orchestrator.supports?(:code_session)
          return "The #{orchestrator.backend_name} sandbox backend cannot run Claude Code sessions"
        end

        "Connect Claude Code in Settings -> Integrations first" if sandbox.runtime_environment.blank?
      end

      # The session of this sandbox that is queued or running, if any: one
      # checkout, one Claude Code at a time.
      def busy_session
        @sandbox.code_sessions.where(status: [ :queued, :running ]).first
      end

      def busy_body(current)
        { error: "A Claude Code session is already #{current.status} in this sandbox", code_session: current.summary }
      end

      def invalid_request(code_session)
        return "model is not a Claude Code model name" if code_session.model && !code_session.model.match?(MODEL_NAME)

        code_session.errors.full_messages.to_sentence unless code_session.valid?
      end

      # A prompt or model sent as an array or object is not one.
      def string_param(name)
        value = params[name]
        value.is_a?(String) ? value : nil
      end

      def stop(code_session)
        SandboxOrchestrator.new.cancel_code_session(@sandbox, code_session)
      rescue StandardError => e
        Rails.logger.warn("Failed to stop Claude Code session #{code_session.id}: #{e.message}")
      end
    end
  end
end
