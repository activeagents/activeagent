# frozen_string_literal: true

module ActionAgent
  module Api
    # Tickets into a checkout sandbox browser's live view (BrowserLiveTicket):
    #
    #   POST /api/sandboxes/:sandbox_id/browser/tickets
    #        mode: "view" (the default) to watch, or "control" to also take over
    #
    # Answers 201 with { ticket:, mode:, expires_at:, url: }, where url is
    # the live view's WebSocket and the ticket is its first message.
    #
    # A view ticket needs only access to the sandbox, found the way
    # SandboxBrowsersController finds it. A control ticket also needs
    # ActionAgent.permitted?(user, :take_over_browser, sandbox), and execution
    # to be enabled. A browser that is not running, or that has no live view,
    # answers 409.
    class SandboxBrowserTicketsController < BaseController
      before_action :set_sandbox

      def create
        mode = params[:mode].presence || "view"
        unless BrowserLiveTicket::MODES.include?(mode)
          return render json: { error: "mode must be one of #{BrowserLiveTicket::MODES.join(', ')}" }, status: :unprocessable_entity
        end
        if mode == "control"
          require_execution_enabled!
          return if performed?
          return unless authorize_action!(:take_over_browser, @sandbox)
        end
        unless @sandbox.browser_running? && @sandbox.browser_live_url.present?
          return render json: { error: "The sandbox's browser has no live view to open", browser: @sandbox.browser_summary },
            status: :conflict
        end

        issued = BrowserLiveTicket.issue(@sandbox, user: current_user, mode: mode)
        response.headers["Cache-Control"] = "no-store"
        render json: issued.merge(expires_at: issued[:expires_at].iso8601, url: @sandbox.browser_live_url), status: :created
      end

      private

      def set_sandbox
        scope = owned(SandboxSession)
        scope = scope.where.not(sandbox_type: "app_runtime").or(scope.where(account_id: current_account.id)) if current_account
        @sandbox = scope.find_by!(session_id: params[:sandbox_id])
      end
    end
  end
end
