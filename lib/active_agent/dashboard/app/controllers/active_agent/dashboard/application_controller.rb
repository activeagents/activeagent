# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Base controller for the ActiveAgent Dashboard.
    #
    # Handles authentication and provides helper methods for multi-tenant mode.
    class ApplicationController < ActionController::Base
      protect_from_forgery with: :exception

      before_action :authenticate_dashboard!

      # Add the engine's view path
      prepend_view_path ActiveAgent::Dashboard::Engine.dashboard_root.join("app", "views").to_s

      # Use custom layout if configured, otherwise use engine layout
      layout -> { ActiveAgent::Dashboard.layout || "active_agent/dashboard/application" }

      helper_method :current_user, :current_owner

      private

      def authenticate_dashboard!
        return if ActiveAgent::Dashboard.authentication_method.nil?

        result = ActiveAgent::Dashboard.authentication_method.call(self)
        head :unauthorized unless result
      rescue StandardError => e
        Rails.logger.error("[ActiveAgent::Dashboard] Authentication error: #{e.message}")
        head :unauthorized
      end

      # Returns the current user from the host application.
      def current_user
        return nil unless ActiveAgent::Dashboard.current_user_method

        send(ActiveAgent::Dashboard.current_user_method)
      rescue NoMethodError
        nil
      end

      # Returns the current owner (account in multi-tenant, user otherwise).
      def current_owner
        if ActiveAgent::Dashboard.multi_tenant? && ActiveAgent::Dashboard.current_account_method
          send(ActiveAgent::Dashboard.current_account_method)
        else
          current_user
        end
      rescue NoMethodError
        nil
      end
    end
  end
end
