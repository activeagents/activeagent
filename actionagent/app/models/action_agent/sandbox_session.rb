# frozen_string_literal: true

module ActionAgent
  class SandboxSession < ApplicationRecord
    include Ownable
    owned_by :user, :account

    belongs_to :agent_template, optional: true
    has_many :code_sessions, dependent: :destroy

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

    # Validations
    validates :session_id, presence: true, uniqueness: true
    validates :sandbox_type, inclusion: { in: SANDBOX_TYPES }
    validates :repository, presence: true, if: :app_runtime?
    validates :repository_ref, length: { maximum: 255 }, format: { without: /\A-|\s|\.\./, message: "is not a valid git ref" },
      allow_blank: true
    validate :repository_available, on: :create, if: :app_runtime?

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
    # sandbox type. Carries the owner's GitHub token, so it goes to the
    # backend and never into a response.
    #
    # @return [Hash, nil]
    def checkout_spec
      return nil unless app_runtime?

      github_connection&.checkout_spec(repository, ref: repository_ref)
    end

    # The GitHub connection whose selection this session's checkout comes
    # from.
    def github_connection
      owners_record(GithubConnection)
    end

    # Environment the backend passes into an app_runtime checkout, so the
    # booted app can run Claude Code sessions against it with the owner's
    # connected credential (Settings -> Integrations). Empty when none is
    # connected. Secret — for the backend, never a response.
    #
    # @return [Hash{String => String}]
    def runtime_environment
      return {} unless app_runtime?

      owners_record(ProviderKey.where(provider: "claude_code"))&.runtime_environment || {}
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
    def provision!
      return if provisioning? || ready?

      update!(status: :provisioning)

      # A checkout always boots in the background: cloning and setting up a
      # real app takes minutes, and a request must not wait on it, in
      # development either. The client polls the session until it is ready
      # (or failed). The other types are simulated in development and test,
      # synchronously for immediate feedback.
      if !app_runtime? && (Rails.env.development? || Rails.env.test?)
        SandboxProvisionJob.perform_now(id)
      else
        SandboxProvisionJob.perform_later(id)
      end
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
    def expire!
      with_lock { update!(status: :expired, runtime_mcp_url: nil, runtime_mcp_token: nil) }
      SandboxCleanupJob.perform_later(id) if cloud_run_job_id.present?
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
        # The key an agent adds to its mcp_servers to use this runtime's
        # tools; nil until the backend has reported the endpoint.
        runtime_server_key: runtime_mcp_url.present? ? runtime_server_key : nil,
        # Why provisioning failed. Scrubbed of the session's secrets when
        # SandboxProvisionJob stored it.
        error_message: error_summary
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
    # necessarily theirs.
    def owners_record(scope)
      scope = scope.all
      case scope.klass.owner_association
      when :account then account_id && scope.find_by(account_id: account_id)
      when :user then user_id && scope.find_by(user_id: user_id)
      else scope.first
      end
    end

    def repository_available
      return if repository.blank?

      connection = github_connection
      if connection.nil?
        errors.add(:repository, "needs a GitHub connection (Settings -> Integrations)")
      elsif (repo = connection.repository(repository))
        # Canonical spelling, and the default branch unless a ref was asked for.
        self.repository = repo["full_name"]
        self.repository_ref = repository_ref.presence || repo["default_branch"]
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
