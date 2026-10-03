# frozen_string_literal: true

module ActionAgent
  module Api
    # A checkout sandbox's browser (SandboxBrowser):
    #
    #   GET    /api/sandboxes/:sandbox_id/browser  { browser: }
    #   POST   /api/sandboxes/:sandbox_id/browser  starts it; mode ("headless",
    #          the default, or "headed") and capabilities (optional tool groups)
    #   DELETE /api/sandboxes/:sandbox_id/browser  stops it
    #
    # Found the way SandboxesController finds a checkout: among the caller's
    # sandboxes, within their current account. A response carries the
    # browser's mode, status, server key and live view URL, never its MCP
    # endpoint or token. The live view may be opened from the dashboard
    # origin the browser was started from, and from
    # ActionAgent.browser_live_origins.
    class SandboxBrowsersController < BaseController
      # A browser runs the sandbox app's pages: the same gate as running an
      # agent, and its own plan limit.
      before_action :require_execution_enabled!, only: [ :create ]
      before_action :set_sandbox
      before_action -> { enforce_quota!(:browser_minutes) }, only: [ :create ]

      def show
        render json: { browser: @sandbox.browser_summary }
      end

      def create
        SandboxBrowser.start(
          @sandbox,
          mode: params[:mode].presence || "headless",
          capabilities: capability_params,
          recording_url: ->(recording) { events_api_session_recording_url(recording) },
          live_origins: [ request.base_url, *ActionAgent.browser_live_origins ]
        )
        render json: { browser: @sandbox.browser_summary }, status: :created
      rescue SandboxBrowser::Error => e
        render json: { error: e.message, browser: @sandbox.reload.browser_summary }, status: :unprocessable_entity
      end

      def destroy
        SandboxBrowser.stop(@sandbox)
        render json: { browser: @sandbox.browser_summary }
      rescue SandboxBrowser::Error => e
        render json: { error: e.message, browser: @sandbox.browser_summary }, status: :unprocessable_entity
      end

      private

      def set_sandbox
        scope = owned(SandboxSession)
        scope = scope.where.not(sandbox_type: "app_runtime").or(scope.where(account_id: current_account.id)) if current_account
        @sandbox = scope.find_by!(session_id: params[:sandbox_id])
      end

      def capability_params
        value = params[:capabilities]
        return [] if value.blank?

        value.is_a?(Array) ? value.map(&:to_s) : [ value.to_s ]
      end
    end
  end
end
