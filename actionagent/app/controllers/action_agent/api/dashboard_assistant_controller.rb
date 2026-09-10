# frozen_string_literal: true

module ActionAgent
  module Api
    class DashboardAssistantController < BaseController
      protect_from_forgery with: :exception

      before_action :require_assistant_enabled!
      before_action :require_owner!
      before_action :require_execution_enabled!, only: :create
      before_action :enforce_execution_quota!, only: :create

      rescue_from DashboardAssistantService::InvalidInput, with: :invalid_input
      rescue_from DashboardAssistantService::ProcessingConsentRequired, with: :processing_consent_required
      rescue_from DashboardAssistantService::SetupRequired, with: :setup_required
      # Rails 8.2 verifies forgery protection from the browser's Sec-Fetch-Site
      # header, renamed the failure to InvalidCrossOriginRequest, and deprecated
      # the old name. Rescue whichever names the running Rails defines, so a
      # rejected request answers with the dashboard's JSON either way.
      # const_defined? does not fire the deprecation the bare constant would.
      rescue_from ActionController::InvalidCrossOriginRequest, with: :invalid_authenticity_token
      if ActionController.const_defined?(:InvalidAuthenticityToken, false)
        rescue_from ActionController::InvalidAuthenticityToken, with: :invalid_authenticity_token
      end

      def show
        render json: DashboardAssistantService.new(owner: current_owner).configuration
      end

      def create
        input = params.to_unsafe_h.symbolize_keys.slice(:message, :history, :provider, :model, :allow_provider_processing)
        assistant = DashboardAssistantService.new(owner: current_owner, **input)
        assistant.validate!
        record_execution_usage
        render json: assistant.call
      rescue StandardError => exception
        raise if exception.is_a?(DashboardAssistantService::InvalidInput) ||
          exception.is_a?(DashboardAssistantService::ProcessingConsentRequired) ||
          exception.is_a?(DashboardAssistantService::SetupRequired) ||
          exception.is_a?(ActiveRecord::Encryption::Errors::Configuration)

        # Provider exceptions can contain credentials or raw request bodies.
        Rails.logger.warn("[DashboardAssistant] Generation failed (#{exception.class.name})")
        render json: { error: "The assistant could not complete this request. Retry, or ask the dashboard administrator to check the server logs.", code: "generation_failed" }, status: :bad_gateway
      end

      private

      # The assistant ships as a development and CI tool (see
      # ActionAgent.assistant_enabled). Where it is off, it is not a view a
      # caller can reach by knowing the route: the dashboard omits it, and
      # both endpoints refuse.
      def require_assistant_enabled!
        return if ActionAgent.assistant_enabled?

        render json: {
          error: "The dashboard assistant is available in development and test. " \
            "Set ActionAgent.assistant_enabled = true to enable it in this environment.",
          code: "assistant_disabled"
        }, status: :forbidden
      end

      def invalid_input(exception)
        render json: { error: exception.message, code: "invalid_input" }, status: :unprocessable_entity
      end

      def processing_consent_required(exception)
        render json: { error: exception.message, code: "processing_consent_required" }, status: :unprocessable_entity
      end

      def setup_required(exception)
        render json: {
          error: exception.message, code: "setup_required", setup_required: true,
          action: { type: "open_settings", path: "/settings", label: "Configure provider" }
        }, status: :service_unavailable
      end

      def invalid_authenticity_token
        render json: { error: "Refresh the dashboard before sending another message", code: "invalid_csrf_token" }, status: :unprocessable_entity
      end
    end
  end
end
