# frozen_string_literal: true

module ActionAgent
  class SandboxSession < ApplicationRecord
    include Ownable
    owned_by :user, :account

    belongs_to :agent_template, optional: true

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

    # Sandbox types
    SANDBOX_TYPES = %w[playwright_mcp terminal research].freeze

    # Free tier limits
    FREE_TIER_LIMITS = {
      max_runs: 10,
      timeout_seconds: 300,
      max_tokens: 50_000,
      session_duration_minutes: 15
    }.freeze

    # Validations
    validates :session_id, presence: true, uniqueness: true
    validates :sandbox_type, inclusion: { in: SANDBOX_TYPES }

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

      # In development, run synchronously for immediate feedback
      if Rails.env.development? || Rails.env.test?
        SandboxProvisionJob.perform_now(id)
      else
        SandboxProvisionJob.perform_later(id)
      end
    end

    # Mark as ready with Cloud Run URL
    def mark_ready!(cloud_run_url:, cloud_run_job_id: nil)
      update!(
        status: :ready,
        cloud_run_url: cloud_run_url,
        cloud_run_job_id: cloud_run_job_id
      )
    end

    # Expire the session
    def expire!
      update!(status: :expired)
      # Cleanup Cloud Run resources
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
        mcp_servers: Array(mcp_servers)
      }
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

    def generate_session_id
      self.session_id ||= SecureRandom.uuid
    end

    def set_expiration
      self.expires_at ||= FREE_TIER_LIMITS[:session_duration_minutes].minutes.from_now
      self.max_runs ||= FREE_TIER_LIMITS[:max_runs]
      self.timeout_seconds ||= FREE_TIER_LIMITS[:timeout_seconds]
    end
  end
end
