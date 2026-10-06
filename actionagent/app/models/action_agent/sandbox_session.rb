# frozen_string_literal: true

module ActionAgent
  class SandboxSession < ApplicationRecord
    include Ownable
    owned_by :user, :account

    belongs_to :agent_template, optional: true
    # The project this checkout was booted for, if any.
    belongs_to :project, class_name: "ActionAgent::Project", optional: true
    has_many :code_sessions, dependent: :destroy
    has_many :draft_pull_requests, dependent: :destroy

    # Session statuses
    enum :status, {
      pending: 0,
      provisioning: 1,
      ready: 2,
      running: 3,
      completed: 4,
      expired: 5,
      failed: 6
    }

    # Sandbox types. +app_runtime+ boots a checkout of one of the owner's
    # GitHub repositories (see GithubConnection) and exposes that app's own
    # runtime, so agents and evaluations can use its tools.
    SANDBOX_TYPES = %w[playwright_mcp terminal research app_runtime].freeze

    # MCP server keys naming a checkout sandbox's app runtime, as an agent's
    # mcp_servers lists them: "sandbox:<session_id>".
    RUNTIME_SERVER_PREFIX = "sandbox:"

    # MCP server keys naming a checkout sandbox's browser:
    # "browser:<session_id>". A run reaches one only through the sandbox it
    # runs against (MCPToolDispatcher's extra_server_keys), never through an
    # agent's saved servers.
    BROWSER_SERVER_PREFIX = "browser:"

    # A browser runs without a window, or with one a person can watch.
    BROWSER_MODES = %w[headless headed].freeze
    BROWSER_STATUSES = %w[starting running stopped failed].freeze
    # Optional Playwright MCP tool groups a browser may be started with.
    BROWSER_CAPABILITIES = %w[testing vision pdf].freeze
    # A browser stops on its own this long before its session expires, so the
    # last events it records are posted while its recording still takes them:
    # SessionRecording#ingest_token_valid? refuses every post once the session
    # has expired.
    BROWSER_STOP_LEAD = 30.seconds

    # Free tier limits
    FREE_TIER_LIMITS = {
      max_runs: 10,
      timeout_seconds: 300,
      max_tokens: 50_000,
      session_duration_minutes: 15
    }.freeze

    # How long a checkout sandbox lives. Booting one (clone, bundle install,
    # db:prepare) can take minutes, and it is worked in for a while after —
    # Claude Code sessions, agents using its tools — so the free tier's 15
    # minutes would expire it about as soon as it was ready.
    APP_RUNTIME_SESSION_DURATION = 2.hours

    encrypts :runtime_mcp_token if ActionAgent.encrypt_credentials
    encrypts :browser_token if ActionAgent.encrypt_credentials

    # What a backend's start_browser needs beyond the session's own columns,
    # set by SandboxBrowser for that one call and never stored. Carries
    # secrets, so it goes to the backend and nowhere else:
    #
    #   token         the bearer token the browser's MCP endpoint is to expect
    #   app_url       the sandbox app the browser may open
    #   capabilities  BROWSER_CAPABILITIES to enable
    #   stop_at       when the browser stops on its own (browser_stops_at)
    #   recording     where to post recorded events: { url:, token:,
    #                 batch_events:, batch_bytes: }, or nil to record nothing
    #
    # @return [Hash, nil]
    attr_accessor :browser_launch

    # Validations
    validates :session_id, presence: true, uniqueness: true
    validates :sandbox_type, inclusion: { in: SANDBOX_TYPES }
    validates :repository, presence: true, if: :app_runtime?
    validates :repository_ref, length: { maximum: 255 }, format: { without: /\A-|\s|\.\./, message: "is not a valid git ref" },
      allow_blank: true
    validate :repository_available, on: :create, if: :app_runtime?
    validates :browser_mode, inclusion: { in: BROWSER_MODES }, allow_nil: true
    validates :browser_status, inclusion: { in: BROWSER_STATUSES }, allow_nil: true

    # Callbacks
    before_validation :generate_session_id, on: :create
    before_create :set_expiration

    # Scopes
    scope :active, -> { where(status: [ :pending, :provisioning, :ready, :running ]) }
    scope :expired_sessions, -> { where("expires_at < ?", Time.current) }
    scope :by_type, ->(type) { where(sandbox_type: type) }
    scope :anonymous, -> { where(user_id: nil) }
    scope :recent, -> { order(created_at: :desc) }

    # Catalog entries for the MCP servers this session was started with.
    # Unknown keys are dropped rather than raising — a session outlives a
    # catalog edit.
    def mcp_catalog_entries
      Array(mcp_servers).filter_map { |key| MCPCatalog.find(key) }
    end

    def self.runtime_server_key?(key)
      key.to_s.start_with?(RUNTIME_SERVER_PREFIX)
    end

    def self.browser_server_key?(key)
      key.to_s.start_with?(BROWSER_SERVER_PREFIX)
    end

    # The MCP catalog entry for a sandbox's browser, looked up among +owner+'s
    # sessions only. Nil unless the session and its browser are running.
    #
    # @return [Hash, nil]
    def self.browser_server_entry(key, owner:)
      return nil unless browser_server_key?(key)

      session = for_owner(owner).find_by(session_id: key.to_s.delete_prefix(BROWSER_SERVER_PREFIX))
      session&.browser_server_entry
    end

    # The MCP catalog entry for a checkout sandbox's app runtime, looked up
    # among +owner+'s sessions only. Nil unless the session is live and its
    # backend reported an endpoint.
    #
    # @return [Hash, nil]
    def self.runtime_server_entry(key, owner:)
      return nil unless runtime_server_key?(key)

      session = for_owner(owner).find_by(session_id: key.to_s.delete_prefix(RUNTIME_SERVER_PREFIX))
      session&.runtime_server_entry
    end

    # The live runtimes in +scope+ (a relation already scoped to an owner) as
    # MCP server listings: the catalog entry shape MCPCatalog serves, without
    # the bearer token runtime_server_entry carries for the dispatcher.
    #
    # @return [Array<Hash>]
    def self.runtime_server_listings(scope)
      scope.active.by_type("app_runtime")
        .where.not(runtime_mcp_url: [ nil, "" ])
        .where("expires_at > ?", Time.current)
        .recent.limit(20)
        .filter_map(&:runtime_server_listing)
    end

    def app_runtime?
      sandbox_type == "app_runtime"
    end

    def runtime_server_key
      "#{RUNTIME_SERVER_PREFIX}#{session_id}"
    end

    # This session's app runtime as an MCP catalog entry — the shape
    # MCPToolDispatcher reaches servers through.
    def runtime_server_entry
      return nil unless app_runtime? && active? && runtime_mcp_url.present?

      {
        key: runtime_server_key,
        name: "#{repository}@#{repository_ref} (sandbox)",
        description: "App runtime booted from a checkout of #{repository}",
        transport: "streamable_http",
        url: runtime_mcp_url,
        headers: runtime_mcp_token.present? ? { "Authorization" => "Bearer #{runtime_mcp_token}" } : {}
      }
    end

    def browser_server_key
      "#{BROWSER_SERVER_PREFIX}#{session_id}"
    end

    def browser_running?
      browser_status == "running" && browser_mcp_url.present? && active?
    end

    # This session's browser as an MCP catalog entry, the shape
    # MCPToolDispatcher reaches servers through, or nil unless it is running.
    # Carries the browser's token, so it is for the dispatcher only.
    #
    # @return [Hash, nil]
    def browser_server_entry
      return nil unless browser_running?

      {
        key: browser_server_key,
        name: "Browser (#{repository} sandbox)",
        description: "The browser of the sandbox booted from #{repository}",
        transport: "streamable_http",
        url: browser_mcp_url,
        headers: browser_token.present? ? { "Authorization" => "Bearer #{browser_token}" } : {}
      }
    end

    # When the browser stops on its own: BROWSER_STOP_LEAD before the session
    # expires.
    #
    # @return [Time, nil]
    def browser_stops_at
      expires_at && expires_at - BROWSER_STOP_LEAD
    end

    # The minutes the browser has run, from its start to +at+ or to
    # browser_stops_at if that is sooner, rounded up to a whole minute and at
    # least 1; 0 when it never started. Capped so that a reaper running late
    # does not count time the browser was no longer running.
    #
    # @return [Integer]
    def browser_minutes(at = Time.current)
      return 0 unless browser_started_at

      stopped_at = [ at, browser_stops_at ].compact.min
      [ ((stopped_at - browser_started_at) / 60.0).ceil, 1 ].max
    end

    # Who this session's browser minutes are metered against: the tenant in a
    # multi-tenant install, the owner ApplicationController#current_owner
    # resolves and the quota checker is asked about, and the session's owner
    # otherwise.
    def metering_owner
      return owner unless ActionAgent.multi_tenant?

      account_class = ActionAgent.account_class.to_s.safe_constantize
      account_class.find_by(id: account_id) if account_class && account_id
    end

    # The browser for an API response: never its token or its MCP endpoint.
    #
    # @return [Hash]
    def browser_summary
      {
        mode: browser_mode,
        status: browser_status,
        started_at: browser_started_at&.iso8601,
        # The key an agent run reaches the browser by; nil unless it runs.
        server_key: browser_running? ? browser_server_key : nil,
        live_url: browser_running? ? browser_live_url : nil
      }
    end

    # This runtime as a token-free MCP server listing (see
    # runtime_server_listings), or nil when it is not live.
    def runtime_server_listing
      entry = runtime_server_entry or return nil

      entry.except(:headers).merge(
        command: nil, package: nil, categories: [ "runtime" ], docs_url: nil,
        sandbox: false, sandbox_type: "app_runtime", first_party: false,
        requires_credentials: [], tools: [], runtime: true
      )
    end

    # What a sandbox backend clones for an app_runtime session: repository,
    # ref, clone URL and the credentials to fetch it. Nil for any other
    # sandbox type, and when the checkout is no longer available. Carries a
    # GitHub token, so it goes to the backend and never into a response.
    #
    # Reading it never calls GitHub. A checkout through the OAuth connection
    # carries the connection's stored token. One through a GitHub App
    # installation carries a token only on the object #mint_checkout_spec!
    # was called on, and +token+ is nil anywhere else.
    #
    # @return [Hash, nil]
    def checkout_spec
      return nil unless app_runtime?
      return @minted_checkout_spec if @minted_checkout_spec

      if github_installation_id
        installation = checkout_installation
        installation&.repository(repository) && installation.checkout_spec(repository, ref: repository_ref)
      else
        github_connection&.checkout_spec(repository, ref: repository_ref)
      end
    end

    # Mints the token a GitHub App checkout is fetched with, and keeps the
    # spec on this object, so #checkout_spec answers with it from here on.
    # SandboxProvisionJob calls this once per provision, hands this same
    # object to the backend, and scrubs the same value from what the boot
    # reports. The token is never stored. A checkout through the OAuth
    # connection mints nothing and returns #checkout_spec.
    #
    # @raise [GithubClient::InstallationUnavailable] when GitHub reports the installation removed or suspended
    # @return [Hash, nil]
    def mint_checkout_spec!
      return checkout_spec unless app_runtime? && github_installation_id
      return @minted_checkout_spec if @minted_checkout_spec

      installation = checkout_installation
      return nil unless installation&.repository(repository)

      @minted_checkout_spec = installation.checkout_spec!(repository, ref: repository_ref)
    end

    # The GitHub connection whose selection this session's checkout comes
    # from, when it does not come from a GitHub App installation.
    def github_connection
      owners_record(GithubConnection)
    end

    # The owner's GitHub App installation this session's checkout comes from,
    # or nil when it comes from the OAuth connection or the installation was
    # unlinked.
    def checkout_installation
      return nil if github_installation_id.nil?

      owners_record(GithubInstallation.where(id: github_installation_id))
    end

    # Environment the backend passes into an app_runtime checkout, so the
    # booted app can run Claude Code sessions against it with the owner's
    # connected credential (Settings -> Integrations). Empty when none is
    # connected. Secret — for the backend, never a response.
    #
    # @return [Hash{String => String}]
    def runtime_environment(runner: "claude_code")
      return {} unless app_runtime?
      return {} unless ProviderKey::CONNECTION_PROVIDERS.include?(runner)

      owners_record(ProviderKey.where(provider: runner))&.runtime_environment || {}
    end

    # The values this session's sandbox holds that must never leave it: the
    # checkout token where one is stored, the Claude Code and Codex
    # credentials it hands its checkout, and its runtime's MCP token. Reads
    # without minting.
    #
    # @return [Array<String>]
    def secret_values
      spec = begin
        checkout_spec
      rescue StandardError
        nil
      end
      [
        spec&.dig(:token),
        *runtime_environment.values,
        *runtime_environment(runner: "codex").values,
        runtime_mcp_token
      ].compact.map(&:to_s).uniq
    end

    # The values of the secrets of the project this checkout was booted for,
    # with their encodings (Project#scrub_values), for scrubbing whatever the
    # sandbox outputs. Empty for a sandbox no project booted, on an install
    # that has not run the projects migration, and when the secrets cannot be
    # read.
    #
    # @return [Array<String>]
    def project_scrub_values
      return [] unless app_runtime? && has_attribute?(:project_id) && project_id

      project&.scrub_values || []
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] sandbox #{session_id}: could not read its project's secrets: #{e.class}")
      []
    end

    # Check if session is still valid
    def active?
      !expired? && !failed? && !completed? && expires_at > Time.current
    end

    # Check if can run more tasks
    def can_run?
      active? && runs_count < max_runs
    end

    # Record a new run (thread-safe for parallel execution)
    def record_run!(task:, result:, duration_ms:, tokens:, screenshots: [], provider: nil)
      run = {
        id: SecureRandom.uuid,
        task: task,
        result: result,
        duration_ms: duration_ms,
        tokens: tokens,
        screenshots: screenshots,
        provider: provider,
        status: "completed",
        created_at: Time.current.iso8601
      }

      # Use pessimistic locking to prevent race conditions when multiple providers run in parallel
      with_lock do
        reload # Reload to get the latest state
        self.runs = runs + [ run ]
        self.runs_count = runs.size
        self.total_tokens += tokens
        self.total_duration_ms += duration_ms
        self.last_activity_at = Time.current
        save!
      end

      run
    end

    # Provision the Cloud Run sandbox
    #
    # @param boot [Hash, nil] how a checkout boots, as
    #   SandboxBootSpec.request_options returns it; nil for the default
    #   ("auto"). Ignored for other sandbox types.
    def provision!(boot: nil)
      return if provisioning? || ready?

      update!(status: :provisioning)

      # A checkout always boots in the background: cloning and setting up a
      # real app takes minutes, and a request must not wait on it, in
      # development either. The client polls the session until it is ready
      # (or failed). The other types are simulated in development and test,
      # synchronously for immediate feedback.
      if !app_runtime? && (Rails.env.development? || Rails.env.test?)
        SandboxProvisionJob.perform_now(id)
      elsif app_runtime? && boot
        SandboxProvisionJob.perform_later(id, "boot" => boot)
      else
        SandboxProvisionJob.perform_later(id)
      end
    end

    # Continues a checkout whose boot failed and was kept (see
    # SandboxOrchestrator#resume_boot), from the step named +from+, or from
    # the one that failed. False, enqueuing nothing, unless the session is a
    # failed checkout that has not expired.
    def resume_boot!(from: nil)
      resumed = with_lock do
        next false unless app_runtime? && failed? && !past_expiry?

        update!(status: :provisioning, error_message: nil)
        true
      end
      SandboxProvisionJob.perform_later(id, "resume" => { "from" => from.presence&.to_s }) if resumed
      resumed
    end

    def past_expiry?
      expires_at.present? && expires_at <= Time.current
    end

    # Mark as ready with Cloud Run URL. A checkout sandbox's backend also
    # reports the app runtime's MCP endpoint and the token it expects.
    def mark_ready!(cloud_run_url:, cloud_run_job_id: nil, runtime_mcp_url: nil, runtime_mcp_token: nil)
      attributes = { status: :ready, cloud_run_url: cloud_run_url, cloud_run_job_id: cloud_run_job_id }
      attributes[:runtime_mcp_url] = runtime_mcp_url if runtime_mcp_url
      attributes[:runtime_mcp_token] = runtime_mcp_token if runtime_mcp_token
      update!(attributes)
    end

    # Expire the session. Its runtime stops being reachable at once — the
    # endpoint and its token are cleared, so no agent is handed a runtime
    # that is going away — and the backend's resource is released by
    # SandboxCleanupJob, which keeps the handle until that succeeds.
    #
    # Under the row lock, which reloads the row first: callers (DELETE, the
    # reaper) loaded this copy earlier, and SandboxProvisionJob may have
    # marked it ready since. Acting on the stale copy would neither clear the
    # endpoint it recorded (nil -> nil writes nothing) nor see the handle to
    # terminate, leaving the booted sandbox running.
    #
    # Its browser is stopped first while the session is still live, so the
    # browser's last recorded events are accepted (SandboxBrowser.stop_before_expiry).
    # When that cannot be done, it stops being reachable the same way as the
    # runtime, its minutes are counted here (SandboxBrowser.finish!), and the
    # cleanup job stops it.
    def expire!
      SandboxBrowser.stop_before_expiry(self)
      with_lock { update!(status: :expired, runtime_mcp_url: nil, runtime_mcp_token: nil) }
      SandboxBrowser.finish!(self)
      # A checkout with no handle may still have a boot behind it (its job
      # died mid-boot, say); the cleanup job asks the backend for it.
      SandboxCleanupJob.perform_later(id) if cloud_run_job_id.present? || app_runtime?
    end

    # The browser token never leaves the model, whatever serializes it.
    def serializable_hash(options = nil)
      options = (options || {}).dup
      options[:except] = Array(options[:except]).map(&:to_s) | %w[browser_token]
      super(options)
    end

    # Summary for API responses
    def summary
      {
        id: id,
        session_id: session_id,
        sandbox_type: sandbox_type,
        status: status,
        runs_count: runs_count,
        max_runs: max_runs,
        total_tokens: total_tokens,
        expires_at: expires_at&.iso8601,
        created_at: created_at.iso8601,
        cloud_run_url: cloud_run_url,
        mcp_servers: Array(mcp_servers),
        repository: repository,
        repository_ref: repository_ref,
        # How a checkout reaches GitHub: "app" (a GitHub App installation) or
        # "oauth" (the OAuth connection).
        checkout_source: app_runtime? ? (github_installation_id ? "app" : "oauth") : nil,
        # The key an agent adds to its mcp_servers to use this runtime's
        # tools; nil until the backend has reported the endpoint.
        runtime_server_key: runtime_mcp_url.present? ? runtime_server_key : nil,
        # Why provisioning failed. Scrubbed of the session's secrets when
        # SandboxProvisionJob stored it.
        error_message: error_summary,
        browser: browser_summary
      }
    end

    # A failed boot's message is a one-line reason followed by the tail of
    # the failing step's log, and the log's last lines usually hold the
    # actual error — so a long message keeps its head and its end.
    ERROR_SUMMARY_HEAD = 300
    ERROR_SUMMARY_TAIL = 1_700

    def error_summary
      return error_message if error_message.nil? || error_message.length <= ERROR_SUMMARY_HEAD + ERROR_SUMMARY_TAIL

      "#{error_message[0, ERROR_SUMMARY_HEAD]}\n…\n#{error_message[-ERROR_SUMMARY_TAIL..]}"
    end

    # Detailed info including runs
    def details
      summary.merge(
        runs: runs,
        total_duration_ms: total_duration_ms,
        last_activity_at: last_activity_at&.iso8601
      )
    end

    private

    # The owner's record in +scope+, found through that model's own owner
    # column. GitHub connections and provider keys are account-owned before
    # user-owned, the opposite of a session, so the session's #owner is not
    # necessarily theirs. Only the rows the model's .owned_rows admits are
    # read, so a member's personal provider key never reaches a sandbox,
    # which every member of the account shares.
    def owners_record(scope)
      owners_records(scope).first
    end

    # Every record of the owner's in +scope+, found the same way.
    def owners_records(scope)
      scope = scope.all
      scope = scope.merge(scope.klass.owned_rows)
      case scope.klass.owner_association
      when :account then account_id ? scope.where(account_id: account_id) : scope.none
      when :user then user_id ? scope.where(user_id: user_id) : scope.none
      else scope
      end
    end

    # A repository selected on one of the owner's GitHub App installations is
    # checked out through that installation, ahead of the OAuth connection,
    # so the checkout gets a short-lived token limited to that repository.
    # Installations count only while a GitHub App is configured, since
    # nothing else can mint their tokens.
    def repository_available
      return if repository.blank?

      installations = ActionAgent.github_app_configured? ? owners_records(GithubInstallation).order(:id).to_a : []
      installation = installations.find { |candidate| candidate.usable? && candidate.repository(repository) }
      connection = github_connection unless installation
      repo = installation&.repository(repository) || connection&.repository(repository)

      if repo
        self.github_installation_id = installation&.id
        # Canonical spelling, and the default branch unless a ref was asked for.
        self.repository = repo["full_name"]
        self.repository_ref = repository_ref.presence || repo["default_branch"]
      elsif installations.any? { |candidate| candidate.repository(repository) }
        errors.add(:repository, "is selected on a GitHub App installation that was removed or suspended: " \
          "reinstall the GitHub App, or Check again once it is unsuspended, in Settings -> Integrations")
      elsif connection.nil? && installations.empty?
        errors.add(:repository, "needs a GitHub connection (Settings -> Integrations)")
      else
        errors.add(:repository, "is not one of the repositories selected in Settings -> Integrations")
      end
    end

    def generate_session_id
      self.session_id ||= SecureRandom.uuid
    end

    def set_expiration
      duration = app_runtime? ? APP_RUNTIME_SESSION_DURATION : FREE_TIER_LIMITS[:session_duration_minutes].minutes
      self.expires_at ||= duration.from_now
      self.max_runs ||= FREE_TIER_LIMITS[:max_runs]
      self.timeout_seconds ||= FREE_TIER_LIMITS[:timeout_seconds]
    end
  end
end
