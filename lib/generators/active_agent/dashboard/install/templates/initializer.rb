# frozen_string_literal: true

# ActiveAgent Dashboard Configuration
#
# This initializer configures the ActiveAgent Dashboard engine.
# See https://docs.activeagents.ai/dashboard for full documentation.

ActiveAgent::Dashboard.configure do |config|
  # ==========================================================================
  # Authentication
  # ==========================================================================

  # Set an authentication method that will be called on all dashboard controllers.
  # This should authenticate the user and redirect/raise if unauthorized.
  #
  # Examples:
  #   config.authentication_method = ->(controller) { controller.authenticate_admin! }
  #   config.authentication_method = ->(controller) { controller.authenticate_user! }
  #
  # config.authentication_method = nil

<% if multi_tenant? -%>
  # ==========================================================================
  # Multi-tenant Mode
  # ==========================================================================

  # Enable multi-tenant mode for SaaS deployments with multiple accounts.
  config.multi_tenant = true

  # The Account model class name
  config.account_class = "Account"

  # The User model class name
  config.user_class = "User"

  # Method to call on controllers to get the current account
  config.current_account_method = :current_account

  # Method to call on controllers to get the current user
  config.current_user_method = :current_user

<% else -%>
  # ==========================================================================
  # Local Mode (default)
  # ==========================================================================

  # Multi-tenant mode is disabled by default.
  # Set to true if you're building a SaaS platform with multiple accounts.
  # config.multi_tenant = false

  # Optional: Associate agents with users
  # config.user_class = "User"
  # config.current_user_method = :current_user

<% end -%>
  # ==========================================================================
  # Sandbox Configuration
  # ==========================================================================

  # Sandbox service type for agent execution environments.
  # Options: :local (Docker/Incus), :cloud_run, :kubernetes
  config.sandbox_service = :local

  # Custom sandbox limits (optional)
  # config.sandbox_limits = {
  #   max_runs: 10,
  #   timeout_seconds: 300,
  #   max_tokens: 50_000,
  #   session_duration_minutes: 15
  # }

  # ==========================================================================
  # UI Configuration
  # ==========================================================================

  # Use Inertia.js with React for the frontend (requires additional setup)
  # config.use_inertia = false

  # Custom layout for dashboard views
  # config.layout = "application"

  # ==========================================================================
  # Storage Configuration
  # ==========================================================================

  # Storage service for screenshots and snapshots.
  # Must respond to #signed_url_for(key, expires_in:) and #fetch_snapshot(key)
  # config.storage_service = MyStorageService.new
end
