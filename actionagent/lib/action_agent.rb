# frozen_string_literal: true

module ActionAgent
  class << self
    # Table name prefix for the engine's models. The engine's own
    # migrations create `active_agent_*` tables, so the default matches.
    #
    # A host app that already owns these tables under different names (the
    # activeagents.ai platform grew them unprefixed) sets this to "" rather
    # than renaming production tables. The engine's migrations read the same
    # value, so the schema and the models never disagree.
    #
    # Defined before the engine is required on purpose: Rails' isolate_namespace
    # installs its own table_name_prefix on an on_load(:active_record) hook
    # unless the module already has one, and that hook would win over any
    # definition made afterwards.
    attr_writer :table_name_prefix

    def table_name_prefix
      global = defined?(::ActiveRecord::Base) ? ::ActiveRecord::Base.table_name_prefix : ""
      "#{global}#{@table_name_prefix ||= "active_agent_"}"
    end

    # Which keyword the installed solid_agent uses to switch has_context's
    # auto-context off: `contextable:` up to 0.1, `contextual:` from 0.2. The
    # gemspec floor admits both, and passing the wrong one raises an
    # ArgumentError deep inside a run rather than at boot — so
    # AgentExecutionService asks rather than assumes.
    #
    # Covered by test/integration/solid_agent, which runs this engine against
    # solid_agent's main branch as well as the released gem.
    def solid_agent_auto_context_keyword
      @solid_agent_auto_context_keyword ||= begin
        keywords = ::SolidAgent::HasContext::ClassMethods
          .instance_method(:has_context).parameters
          .select { |type, _| [ :key, :keyreq ].include?(type) }
          .map(&:last)

        keywords.include?(:contextual) ? :contextual : :contextable
      end
    end
  end
end

# Both are hard requirements, and both must be loaded here rather than left to
# the host app's Gemfile. Bundler.require only requires the gems an app lists
# directly, so a transitive dependency is installed and activated but never
# loaded:
#
#   * active_agent — Compatibility.install! below dereferences ::ActiveAgent at
#     load time. An app whose Gemfile happens to list actionagent first (which
#     RuboCop's Bundler/OrderedGems will produce, since it sorts before
#     activeagent) would otherwise die at Bundler.require.
#   * solid_agent — AgentExecutionService includes SolidAgent::HasContext in the
#     agent class it builds for every run, so without this every Run fails with
#     an uninitialized-constant error on any install that does not list the gem
#     itself.
require "active_agent"
require "solid_agent"

require "action_agent/version"
require "action_agent/engine"
require "action_agent/compatibility"

# Dashboard engine for visualizing telemetry data and managing agents.
#
# Mount the engine in your routes to access the full dashboard:
#
#   # config/routes.rb
#   mount ActionAgent::Engine => "/activeagents"
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
#   ActionAgent.configure do |config|
#     config.authentication_method = ->(controller) { controller.authenticate_admin! }
#     # Sandboxes run in the in-memory mock unless the app registers a real
#     # backend (see sandbox_backends) and names it here:
#     config.sandbox_backends = { "incus" => "IncusSandboxService" }
#     config.sandbox_service = :incus
#     # Code sessions hand an agent to a coding agent in a code-on-incus
#     # container; the in-memory mock is used until a backend is named:
#     config.code_session_backend = :code_on_incus
#     config.code_on_incus.ssh_target = "coi@incus-host"
#   end
#
# == Multi-tenant Mode
# For SaaS platforms with multiple accounts:
#
#   ActionAgent.configure do |config|
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
module ActionAgent
  class << self
    # Deprecation warnings for this gem, routed through Rails' machinery so a
    # host app can silence or escalate them like any other.
    def deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("2.0", "ActionAgent")
    end

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

    # Method to call on controller to get current account (multi-tenant mode).
    # Only usable when the host app has mixed that method into the engine's
    # controllers; otherwise use current_account_resolver.
    # @return [Symbol, nil]
    attr_accessor :current_account_method

    # Method to call on controller to get current user. Same caveat as
    # current_account_method — see current_user_resolver.
    # @return [Symbol, nil]
    attr_accessor :current_user_method

    # Resolves the signed-in user from the controller. Preferred over
    # current_user_method: the engine's controllers are their own base
    # class, so a host app's `current_user` helper is not on them unless
    # the app deliberately put it there.
    # @return [Proc, nil]
    attr_accessor :current_user_resolver

    # Resolves the current tenant from the controller. See
    # current_user_resolver.
    # @return [Proc, nil]
    attr_accessor :current_account_resolver

    # The tenant whose telemetry relates to +owner+. Traces belong to
    # accounts while agents may belong to users, so the two are not always
    # the same record and a host app says how to get from one to the other.
    # @return [Proc, nil]
    attr_accessor :tenant_resolver

    # The agents an owner can reach. Defaults to the ones that owner owns.
    # A host app where those differ — the platform's agents belong to users
    # while its API keys belong to accounts — supplies its own scope.
    # @return [Proc, nil]
    attr_accessor :agent_scope_resolver

    # Custom trace model class (for host app overrides)
    # @return [String, nil]
    attr_accessor :trace_model_class

    # Enable React/Inertia frontend instead of ERB
    # @return [Boolean]
    attr_accessor :use_inertia

    # Custom layout for the dashboard
    # @return [String, nil]
    attr_accessor :layout

    # Which sandbox backend to provision with: :mock (the only one the
    # engine ships — an in-memory fake that runs nothing) or the name of a
    # backend the host registered in sandbox_backends. An unregistered name
    # falls back to :mock with a logged warning.
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
    # returns nil to allow, or to deny: a message String, or a Hash merged
    # into the response so the app can surface its own usage numbers.
    # Denials surface as HTTP 402 (execution) / 429 (ingest).
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

    # Sandbox backends contributed by the host app, as
    # { "cloud_run" => "CloudRunService" }. The engine ships only :mock;
    # every real backend (Docker/Incus, Cloud Run, Kubernetes) lives in the
    # app that operates it, which registers it here and selects it with
    # sandbox_service.
    # @return [Hash{String => String}]
    attr_accessor :sandbox_backends

    # Whether the dashboard may execute agents against real providers.
    # Disable to run the dashboard as a read-only observability surface.
    # @return [Boolean]
    attr_accessor :execution_enabled

    # Where the dashboard's upgrade CTAs should send people. Unset in a
    # self-hosted install, where there is nothing to upgrade, and the CTAs
    # say so instead of linking nowhere.
    # @return [String, nil]
    attr_accessor :upgrade_url

    # The host app's sign-out endpoint, which the header's "Sign out" item
    # POSTs to (with _method=delete and the CSRF token). The engine has no
    # session of its own; unset, the menu item is not shown.
    # @return [String, nil]
    attr_accessor :sign_out_path

    # Where a browser is sent when it asks for a dashboard page without a
    # valid session — the host app's sign-in page. Unset, an unauthenticated
    # page request gets a minimal session-expired page instead of a bare
    # 401; API clients always get the 401.
    # @return [String, nil]
    attr_accessor :sign_in_path

    # Answers GET <mount>/api/usage — the plan meter the Organization view
    # and the Run Agents quota banner read. Receives (owner) and returns a
    # Hash in the platform's shape:
    #
    #   { runs_used: 12, runs_limit: 100, runs_remaining: 88,
    #     can_run: true, plan: "pro" }
    #
    # Unset means unlimited: the engine reports UNLIMITED_USAGE and the
    # views hide the meter.
    # @return [Proc, nil]
    attr_accessor :usage_resolver

    # What a dashboard with no usage_resolver reports: no limit, nothing
    # counted, always allowed.
    UNLIMITED_USAGE = {
      runs_used: 0, runs_limit: nil, runs_remaining: nil, can_run: true, plan: nil, unlimited: true
    }.freeze

    # Called after the dashboard performs a metered action, as
    # (owner, kind) — the counterpart to quota_checker, for host apps that
    # track usage against a plan. Unset means nothing is counted.
    # @return [Proc, nil]
    attr_accessor :usage_recorder

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

    # MCP servers the host app itself serves or connects, appended to the
    # built-in catalog (MCPCatalog) so the MCP Services view lists them and
    # telemetry traffic attributes to them. Each entry is a hash shaped like
    # a catalog entry: +key+ and +name+ at minimum, plus any of the optional
    # fields (+description+, +transport+, +url+, +categories+, +docs_url+,
    # +first_party+); +tool_hints+ names the bare tool names that belong to
    # the server. A built-in entry keeps its key on collision.
    # @return [Array<Hash>]
    attr_accessor :mcp_catalog

    # Value stored in polymorphic *_type columns for dashboard agents
    # (agent_memories.memorable_type, agent_contexts.contextable_type).
    # Unset means the class name. A host app whose existing rows were
    # written under its own constant sets its name here.
    # @return [String, nil]
    attr_accessor :agent_polymorphic_name

    # Code session backends contributed by the host app, as
    # { "firecracker" => "FirecrackerCodeBackend" }, alongside the two the
    # engine ships: "mock" (in-memory, runs nothing) and "code_on_incus"
    # (shells out to the coi CLI, locally or over ssh). A backend is any
    # object answering the protocol CodeSessionOrchestrator documents.
    # @return [Hash{String => String}]
    attr_accessor :code_session_backends

    # Which code session backend to launch coding agents with: :mock by
    # default, so a fresh install can exercise the Code Sessions view without
    # an Incus host. The CODE_SESSION_BACKEND environment variable overrides
    # it (see CodeSessionOrchestrator.default_backend), and an unregistered
    # name falls back to :mock with a logged warning rather than raising.
    # @return [Symbol, String]
    attr_accessor :code_session_backend

    # Guardrails for code sessions, merged over DEFAULT_CODE_SESSION_LIMITS
    # so a host app overrides only the keys it cares about:
    #
    #   session_duration_minutes: how long a sandbox lives before it expires
    #   run_timeout_seconds:      how long one headless run may take
    #   max_sessions_per_owner:   concurrent active sessions per owner
    #
    # @return [Hash{Symbol => Integer}]
    attr_writer :code_session_limits

    DEFAULT_CODE_SESSION_LIMITS = {
      session_duration_minutes: 240,
      run_timeout_seconds: 3600,
      max_sessions_per_owner: 5
    }.freeze

    def code_session_limits
      DEFAULT_CODE_SESSION_LIMITS.merge((@code_session_limits || {}).to_h.symbolize_keys)
    end

    # Resolves the GitHub token a code session clones and pushes with.
    # Receives (owner, session) and returns the token String, or nil to fall
    # back to a stored "github" ProviderKey and then (single-tenant only) to
    # ENV["GITHUB_TOKEN"] — see github_token_for. The token is handed to the
    # backend for the life of the sandbox and never written to the database.
    # @return [Proc, nil]
    attr_accessor :github_token_resolver

    # Settings for the code_on_incus backend, an OrderedOptions so an
    # initializer can write `config.code_on_incus.ssh_target = "coi@host"`:
    #
    #   binary:       the coi executable ("coi")
    #   ssh_target:   run coi on another host over ssh (nil runs it locally)
    #   state_dir:    where per-session profiles, briefs and secrets live;
    #                 nil means tmp/action_agent/code_sessions under Rails.root
    #                 (on the ssh host when ssh_target is set)
    #   base_profile: the coi profile every session inherits ("hardened")
    #   image:        a container image override for coi (nil keeps coi's)
    #   cpu_limit / memory_limit: coi [limits] values
    #   allowlist:    hosts reachable under network_mode "allowlist"
    #
    # @return [ActiveSupport::OrderedOptions]
    attr_reader :code_on_incus

    # Hosts a sandbox may reach in "allowlist" network mode: GitHub for the
    # clone and push, the package registries a test suite needs, and the
    # coding agents' own provider APIs.
    DEFAULT_CODE_ON_INCUS_ALLOWLIST = %w[
      github.com api.github.com codeload.github.com objects.githubusercontent.com
      rubygems.org index.rubygems.org registry.npmjs.org pypi.org files.pythonhosted.org
      api.anthropic.com api.openai.com api.githubcopilot.com
    ].freeze

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

    # Tells the host app that +owner+ performed +kind+. Never raises: a
    # bookkeeping failure must not fail the action that was already taken.
    def record_usage(owner, kind)
      usage_recorder&.call(owner, kind)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] usage recording failed: #{e.message}")
      nil
    end

    # The usage meter for +owner+. Never raises: a bookkeeping failure must
    # not take the views that display it down with it.
    #
    # @return [Hash] the platform's usage shape, UNLIMITED_USAGE by default
    def usage_for(owner)
      return UNLIMITED_USAGE.dup if usage_resolver.nil?

      usage_resolver.call(owner) || UNLIMITED_USAGE.dup
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] usage lookup failed: #{e.message}")
      UNLIMITED_USAGE.dup
    end

    # Asks the host app whether +owner+ may perform +kind+.
    #
    # @return [String, Hash, nil] denial message or payload, nil when allowed
    def quota_denial(owner, kind)
      return nil if quota_checker.nil?

      quota_checker.call(owner, kind)
    end

    # The GitHub token a code session for +owner+ should clone with, or nil
    # when none is configured: the host app's github_token_resolver first,
    # then a "github" ProviderKey the owner stored under Settings, then
    # ENV["GITHUB_TOKEN"] — but only in single-tenant mode, where the
    # process environment belongs to the one operator rather than to every
    # tenant at once. Never raises, and the value must not be logged or
    # persisted by the caller: it exists only to be handed to a backend.
    #
    # @return [String, nil]
    def github_token_for(owner, session = nil)
      if github_token_resolver
        begin
          token = github_token_resolver.call(owner, session)
          return token if token.present?
        rescue StandardError => e
          Rails.logger.warn("[ActionAgent] GitHub token lookup failed: #{e.message}")
          return nil
        end
      end

      stored = ActionAgent::ProviderKey.for_owner(owner).find_by(provider: "github")&.credential
      return stored if stored.present?
      return nil if multi_tenant?

      ENV["GITHUB_TOKEN"].presence
    rescue StandardError => e
      # A missing table (install without the dashboard migrations) is not a
      # reason to fail the session; it just has no token.
      Rails.logger.warn("[ActionAgent] GitHub token lookup failed: #{e.message}")
      nil
    end

    # Provider options for +owner+, or {} when the host app has none and
    # config/active_agent.yml should be used as-is.
    #
    # @return [Hash]
    def provider_credentials(owner, provider)
      return {} if provider_credentials_resolver.nil?

      provider_credentials_resolver.call(owner, provider) || {}
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] provider credential lookup failed: #{e.message}")
      {}
    end

    # Returns the trace model class to use.
    #
    # @return [Class] The trace model class
    def trace_model
      if trace_model_class
        trace_model_class.constantize
      else
        ActionAgent::TelemetryTrace
      end
    end

    # The tenant +owner+ belongs to. Identity unless the host app says
    # otherwise, which is right for every single-tenant install.
    def tenant_for(owner)
      return owner if tenant_resolver.nil?

      tenant_resolver.call(owner)
    end

    # The agents +owner+ can reach.
    #
    # @return [ActiveRecord::Relation]
    def agents_for(owner)
      return agent_model.for_owner(owner) if agent_scope_resolver.nil?

      agent_scope_resolver.call(owner) || agent_model.none
    end

    # Returns the agent model class to use.
    #
    # @return [Class] The agent model class
    def agent_model
      ActionAgent::Agent
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
      @current_user_resolver = nil
      @current_account_resolver = nil
      @agent_scope_resolver = nil
      @tenant_resolver = nil
      @trace_model_class = nil
      @use_inertia = false
      @layout = nil
      @sandbox_service = :mock
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
      @usage_recorder = nil
      @usage_resolver = nil
      @upgrade_url = nil
      @sign_out_path = nil
      @sign_in_path = nil
      @mcp_catalog = []
      @code_session_backends = {}
      @code_session_backend = :mock
      @code_session_limits = nil
      @github_token_resolver = nil
      @code_on_incus = ActiveSupport::OrderedOptions.new.merge!(
        binary: "coi",
        ssh_target: nil,
        state_dir: nil,
        base_profile: "hardened",
        image: nil,
        cpu_limit: "4",
        memory_limit: "8GB",
        allowlist: DEFAULT_CODE_ON_INCUS_ALLOWLIST.dup
      )
    end
  end

  # Set defaults
  reset!
end

ActionAgent::Compatibility.install!
