# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Manages sandbox execution sessions for agent runs.
    #
    # Sandbox sessions provide isolated execution environments for running
    # agents with tools like browser automation, file system access, etc.
    #
    # Supports both local (Docker/Incus) and cloud (Cloud Run) sandbox providers.
    #
    # @example Creating a sandbox session
    #   session = ActiveAgent::Dashboard::SandboxSession.create!(
    #     sandbox_type: "playwright_mcp"
    #   )
    #   session.provision!
    #
    class SandboxSession < ApplicationRecord
      # Owner associations - optional to support anonymous users
      belongs_to :user, class_name: ActiveAgent::Dashboard.user_class, optional: true if ActiveAgent::Dashboard.user_class
      belongs_to :account, class_name: ActiveAgent::Dashboard.account_class, optional: true if ActiveAgent::Dashboard.multi_tenant?
      belongs_to :agent_template, class_name: "ActiveAgent::Dashboard::AgentTemplate", optional: true

      has_many :sandbox_runs, class_name: "ActiveAgent::Dashboard::SandboxRun", dependent: :destroy
      has_one :session_recording, class_name: "ActiveAgent::Dashboard::SessionRecording", dependent: :nullify

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

      # Default limits (can be overridden by platform tier limits)
      DEFAULT_LIMITS = {
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
      before_create :set_defaults

      # Scopes
      scope :active, -> { where(status: [ :pending, :provisioning, :ready, :running ]) }
      scope :expired_sessions, -> { where("expires_at < ?", Time.current) }
      scope :by_type, ->(type) { where(sandbox_type: type) }
      scope :anonymous, -> { where(user_id: nil) }
      scope :recent, -> { order(created_at: :desc) }

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

        with_lock do
          reload
          self.runs = runs + [ run ]
          self.runs_count = runs.size
          self.total_tokens += tokens
          self.total_duration_ms += duration_ms
          self.last_activity_at = Time.current
          save!
        end

        run
      end

      # Provision the sandbox
      def provision!
        return if provisioning? || ready?

        update!(status: :provisioning)

        # Use configured sandbox service
        if Rails.env.development? || Rails.env.test?
          ActiveAgent::Dashboard::SandboxProvisionJob.perform_now(id)
        else
          ActiveAgent::Dashboard::SandboxProvisionJob.perform_later(id)
        end
      end

      # Mark as ready with sandbox URL
      def mark_ready!(sandbox_url:, sandbox_job_id: nil)
        update!(
          status: :ready,
          cloud_run_url: sandbox_url,
          cloud_run_job_id: sandbox_job_id
        )
      end

      # Expire the session
      def expire!
        update!(status: :expired)
        ActiveAgent::Dashboard::SandboxCleanupJob.perform_later(id) if cloud_run_job_id.present?
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
          cloud_run_url: cloud_run_url
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

      def set_defaults
        limits = ActiveAgent::Dashboard.sandbox_limits || DEFAULT_LIMITS
        self.expires_at ||= limits[:session_duration_minutes].minutes.from_now
        self.max_runs ||= limits[:max_runs]
        self.timeout_seconds ||= limits[:timeout_seconds]
      end
    end
  end
end
