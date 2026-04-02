# frozen_string_literal: true

require "active_agent/dashboard/engine"

module ActiveAgent
  # Dashboard engine for visualizing telemetry data and managing agents.
  #
  # Mount the engine in your routes to access the full dashboard:
  #
  #   # config/routes.rb
  #   mount ActiveAgent::Dashboard::Engine => "/active_agent"
  #
  # The dashboard provides:
  # - Agent management: Create, edit, version, and execute agents
  # - Traces view: See all agent invocations with spans, timing, and token usage
  # - Metrics view: Aggregate statistics and charts
  # - Sandbox execution: Run agents in isolated environments
  # - Session recordings: Capture and replay browser sessions
  #
  # = Configuration Modes
  #
  # == Local Mode (default)
  # For self-hosted, single-tenant deployments:
  #
  #   ActiveAgent::Dashboard.configure do |config|
  #     config.authentication_method = ->(controller) { controller.authenticate_admin! }
  #     config.sandbox_service = :local  # Docker/Incus
  #   end
  #
  # == Multi-tenant Mode
  # For SaaS platforms with multiple accounts:
  #
  #   ActiveAgent::Dashboard.configure do |config|
  #     config.multi_tenant = true
  #     config.account_class = "Account"
  #     config.user_class = "User"
  #     config.current_account_method = :current_account
  #     config.current_user_method = :current_user
  #     config.authentication_method = ->(controller) { controller.authenticate_user! }
  #     config.sandbox_service = :cloud_run  # Managed
  #     config.use_inertia = true
  #   end
  #
  module Dashboard
    class << self
      # Authentication method to call on controllers
      # @return [Proc, nil] A proc that receives the controller instance
      attr_accessor :authentication_method

      # Enable multi-tenant mode (requires account association)
      # @return [Boolean]
      attr_accessor :multi_tenant

      # Class name for the Account model (multi-tenant mode)
      # @return [String, nil]
      attr_accessor :account_class

      # Class name for the User model
      # @return [String, nil]
      attr_accessor :user_class

      # Method to call on controller to get current account (multi-tenant mode)
      # @return [Symbol, nil]
      attr_accessor :current_account_method

      # Method to call on controller to get current user
      # @return [Symbol, nil]
      attr_accessor :current_user_method

      # Custom trace model class (for host app overrides)
      # @return [String, nil]
      attr_accessor :trace_model_class

      # Enable React/Inertia frontend instead of ERB
      # @return [Boolean]
      attr_accessor :use_inertia

      # Custom layout for the dashboard
      # @return [String, nil]
      attr_accessor :layout

      # Sandbox service type (:local, :cloud_run, :kubernetes)
      # @return [Symbol]
      attr_accessor :sandbox_service

      # Custom sandbox limits (overrides defaults)
      # @return [Hash, nil]
      attr_accessor :sandbox_limits

      # Storage service for screenshots/snapshots
      # @return [Object, nil] Object responding to #signed_url_for and #fetch_snapshot
      attr_accessor :storage_service

      # Base controller class for dashboard controllers
      # @return [String]
      attr_accessor :base_controller_class

      # Returns whether multi-tenant mode is enabled.
      #
      # @return [Boolean]
      def multi_tenant?
        @multi_tenant == true
      end

      # Returns the trace model class to use.
      #
      # @return [Class] The trace model class
      def trace_model
        if trace_model_class
          trace_model_class.constantize
        else
          ActiveAgent::TelemetryTrace
        end
      end

      # Returns the agent model class to use.
      #
      # @return [Class] The agent model class
      def agent_model
        ActiveAgent::Dashboard::Agent
      end

      # Configures the dashboard.
      #
      # @yield [config] Configuration block
      def configure
        yield self
      end

      # Reset configuration to defaults
      def reset!
        @authentication_method = nil
        @multi_tenant = false
        @account_class = nil
        @user_class = nil
        @current_account_method = nil
        @current_user_method = nil
        @trace_model_class = nil
        @use_inertia = false
        @layout = nil
        @sandbox_service = :local
        @sandbox_limits = nil
        @storage_service = nil
        @base_controller_class = "ActionController::Base"
      end
    end

    # Set defaults
    reset!
  end
end
