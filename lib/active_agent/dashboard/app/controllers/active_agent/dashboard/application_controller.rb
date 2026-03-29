# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Base controller for the ActiveAgent Dashboard.
    #
    # Handles authentication via configurable authentication_method.
    class ApplicationController < ActionController::Base
      protect_from_forgery with: :exception

      before_action :authenticate_dashboard!

      # Add the engine's view path
      prepend_view_path ActiveAgent::Dashboard::Engine.dashboard_root.join("app", "views").to_s

      layout "active_agent/dashboard/application"

      private

      def authenticate_dashboard!
        return if ActiveAgent::Dashboard.authentication_method.nil?

        result = ActiveAgent::Dashboard.authentication_method.call(self)
        head :unauthorized unless result
      rescue StandardError => e
        Rails.logger.error("[ActiveAgent::Dashboard] Authentication error: #{e.message}")
        head :unauthorized
      end
    end
  end
end
