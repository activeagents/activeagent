# frozen_string_literal: true

require "active_agent/dashboard/engine"

module ActiveAgent
  # Dashboard engine for visualizing telemetry data.
  #
  # Mount the engine in your routes to access the telemetry dashboard:
  #
  #   # config/routes.rb
  #   mount ActiveAgent::Dashboard::Engine => "/active_agent"
  #
  # The dashboard provides:
  # - Traces view: See all agent invocations with spans, timing, and token usage
  # - Metrics view: Aggregate statistics and charts
  # - Local storage mode: Store traces in your own database
  # - Multi-tenant mode: For platforms with multiple accounts
  #
  # @example Local mode configuration (default)
  #   ActiveAgent::Dashboard.configure do |config|
  #     config.authentication_method = ->(controller) { controller.authenticate_admin! }
  #   end
  #
  # @example Multi-tenant mode configuration (for activeagents.ai)
  #   ActiveAgent::Dashboard.configure do |config|
  #     config.multi_tenant = true
  #     config.account_class = "Account"
  #     config.current_account_method = :current_account
  #     config.authentication_method = ->(controller) { controller.authenticate_user! }
  #   end
  #
  module Dashboard
    class << self
      # Authentication method to call on controllers
      attr_accessor :authentication_method

      # Enable multi-tenant mode (requires account association)
      attr_accessor :multi_tenant

      # Class name for the Account model (multi-tenant mode)
      attr_accessor :account_class

      # Method to call on controller to get current account (multi-tenant mode)
      attr_accessor :current_account_method

      # Custom trace model class (for host app overrides)
      attr_accessor :trace_model_class

      # Enable React/Inertia frontend instead of ERB
      attr_accessor :use_inertia

      # Custom layout for the dashboard
      attr_accessor :layout

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
        @current_account_method = nil
        @trace_model_class = nil
        @use_inertia = false
        @layout = nil
      end
    end

    # Set defaults
    reset!
  end
end
