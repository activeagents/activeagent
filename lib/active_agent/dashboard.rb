# frozen_string_literal: true

require "active_agent/dashboard/engine"

module ActiveAgent
  # Dashboard engine for visualizing telemetry data and managing agents.
  #
  # Mount the engine in your routes to access the full dashboard:
  #
  #   # config/routes.rb
  #   mount ActiveAgent::Dashboard::Engine => "/activeagents"
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

      # Bearer token required by the ingest API in single-tenant mode. When
      # unset the local ingest endpoint accepts unauthenticated posts, so set
      # it whenever the mount is reachable beyond your own machine.
      # (Multi-tenant mode authenticates per-account keys instead.)
      # @return [String, nil]
      attr_accessor :ingest_api_key

      # @deprecated Never consumed — dashboard controllers inherit
      #   ActionController::Base. Retained as a no-op so existing
      #   initializers that set it keep booting; remove in the next major.
      # @return [String]
      attr_accessor :base_controller_class

      # Called before each run/trace-ingest to enforce host-app limits.
      # Receives (owner, kind) where kind is :execution or :trace_ingest, and
      # returns nil to allow or a message String to deny. Denials surface as
      # HTTP 402 (execution) / 429 (ingest).
      #
      # Unset means unlimited, which is what a self-hosted install wants.
      # @return [Proc, nil]
      attr_accessor :quota_checker

      # Resolves LLM provider credentials for a run. Receives
      # (owner, provider_name) and returns a Hash merged into the agent's
      # generation options (e.g. { access_token: "sk-..." } or
      # { host: "http://localhost:11434" }), or nil to fall back to the
      # host app's config/active_agent.yml.
      #
      # Unset means config/active_agent.yml is the only source, which is what
      # a self-hosted install wants.
      # @return [Proc, nil]
      attr_accessor :provider_credentials_resolver

      # Extra sandbox backends contributed by the host app, as
      # { "cloud_run" => "CloudRunService" }. The engine ships :mock and
      # :local (Docker); cloud backends live in the app that operates them.
      # @return [Hash{String => String}]
      attr_accessor :sandbox_backends

      # Whether the dashboard may execute agents against real providers.
      # Disable to run the dashboard as a read-only observability surface.
      # @return [Boolean]
      attr_accessor :execution_enabled

      # Maps an ingested trace to the owner that its newly observed agents
      # belong to. Defaults to the trace's account in multi-tenant mode and to
      # nobody in single-tenant mode. A host app whose agents hang off a
      # different record (the platform's hang off the account's owning user)
      # supplies its own mapping.
      # @return [Proc, nil]
      attr_accessor :trace_owner_resolver

      # How long telemetry traces are kept before TraceRetentionJob prunes
      # them. A Duration applies to every trace; a callable receives each
      # owner and returns that owner's window (nil keeps everything). Unset
      # means nothing is ever deleted.
      # @return [ActiveSupport::Duration, Proc, nil]
      attr_accessor :trace_retention

      # Whether API keys and provider credentials are encrypted at rest with
      # Active Record Encryption. On by default, which requires the host app
      # to have run `rails db:encryption:init`. Turning it off stores those
      # secrets in plain text — a deliberate downgrade, never a default.
      # @return [Boolean]
      attr_accessor :encrypt_credentials

      # Value stored in polymorphic *_type columns for dashboard agents
      # (agent_memories.memorable_type, agent_contexts.contextable_type).
      # Unset means the class name. A host app whose existing rows were
      # written under its own constant sets its name here.
      # @return [String, nil]
      attr_accessor :agent_polymorphic_name

      # Table name prefix for the engine's models. The engine's own
      # migrations create `active_agent_*` tables, so the default matches.
      #
      # A host app that already owns these tables under different names
      # (the activeagents.ai platform grew them unprefixed) sets this to ""
      # rather than renaming production tables.
      # @return [String]
      attr_accessor :table_name_prefix

      # Returns whether multi-tenant mode is enabled.
      #
      # @return [Boolean]
      def multi_tenant?
        @multi_tenant == true
      end

      # Returns whether agent execution is permitted.
      #
      # @return [Boolean]
      def execution_enabled?
        @execution_enabled != false
      end

      # Asks the host app whether +owner+ may perform +kind+.
      #
      # @return [String, nil] denial message, or nil when allowed
      def quota_denial(owner, kind)
        return nil if quota_checker.nil?

        quota_checker.call(owner, kind)
      end

      # Provider options for +owner+, or {} when the host app has none and
      # config/active_agent.yml should be used as-is.
      #
      # @return [Hash]
      def provider_credentials(owner, provider)
        return {} if provider_credentials_resolver.nil?

        provider_credentials_resolver.call(owner, provider) || {}
      rescue StandardError => e
        Rails.logger.warn("[ActiveAgent::Dashboard] provider credential lookup failed: #{e.message}")
        {}
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

      # Returns the configured owner class: the Account in multi-tenant mode,
      # the User otherwise. Nil when the host app configured neither, which
      # is the single-user self-hosted case.
      #
      # @return [Class, nil]
      def owner_class
        name = multi_tenant? ? account_class : user_class
        name&.safe_constantize
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
        @ingest_api_key = nil
        @base_controller_class = "ActionController::Base" # deprecated no-op
        @quota_checker = nil
        @provider_credentials_resolver = nil
        @sandbox_backends = {}
        @execution_enabled = true
        @table_name_prefix = "active_agent_"
        @agent_polymorphic_name = nil
        @encrypt_credentials = true
        @trace_retention = nil
        @trace_owner_resolver = nil
      end
    end

    # Set defaults
    reset!
  end
end
