# frozen_string_literal: true

module ActionAgent
  # One hand-off of a dashboard agent to a sandboxed coding agent.
  #
  # A session pairs three things: the agent being improved, the brief
  # compiled from that agent's evaluations and metrics (CodeSessionBrief),
  # and a container running a coding agent (Claude Code, Codex, Copilot, an
  # open-source agent) with optional GitHub access to a repository.
  #
  # No credential is a column here. The GitHub token and the coding agent's
  # provider key are resolved per launch, handed to the backend, and deleted
  # with the sandbox — so a leaked row leaks a task and a transcript, never a
  # way to push to someone's repository.
  class CodeSession < ApplicationRecord
    include Ownable
    owned_by :user, :account

    belongs_to :agent, optional: true
    belongs_to :evaluation_run, optional: true

    # pending      created, nothing provisioned yet
    # provisioning the backend is building the sandbox
    # ready        the sandbox exists and can run
    # running      a headless run is in flight
    # completed    the last run exited 0
    # failed       provisioning or the last run failed
    # expired      outlived expires_at and was reclaimed
    # stopped      the operator stopped it
    enum :status, {
      pending: 0, provisioning: 1, ready: 2, running: 3,
      completed: 4, failed: 5, expired: 6, stopped: 7
    }

    # What the session may do with the repository it was given. "none" still
    # allows a public clone; "read" clones private repositories; "write" is
    # what a coding agent needs to push a branch and open a pull request.
    GITHUB_ACCESS = %w[none read write].freeze

    # code-on-incus network modes, in increasing order of reach.
    NETWORK_MODES = %w[restricted allowlist open].freeze

    # "owner/repo", the form every backend clones from. Rejects a path
    # segment that could climb out of it.
    REPOSITORY_FORMAT = %r{\A[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*\z}
    # git's own rules, narrowed: no leading dash (it would read as a flag),
    # no "..", no trailing slash or dot.
    BRANCH_FORMAT = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]{0,199}\z}

    MAX_TASK_LENGTH = 20_000
    MAX_TRANSCRIPT_BYTES = 200_000

    before_validation :generate_session_id, on: :create
    before_validation :normalize_repository
    before_create :set_expiration

    validates :session_id, presence: true, uniqueness: true
    validates :tool, inclusion: { in: ->(_record) { CodeAgentCatalog.keys } }
    validates :backend, presence: true
    validate :backend_registered
    validates :github_access, inclusion: { in: GITHUB_ACCESS }
    validates :network_mode, inclusion: { in: NETWORK_MODES }
    validates :repository, format: { with: REPOSITORY_FORMAT, message: "must look like owner/repo" }, allow_blank: true
    validates :branch, format: { with: BRANCH_FORMAT, message: "is not a valid branch name" }, allow_blank: true
    validate :branch_has_no_parent_traversal
    validates :task, length: { maximum: MAX_TASK_LENGTH }
    validates :model, length: { maximum: 200 }, allow_blank: true

    scope :recent, -> { order(created_at: :desc) }
    scope :active, -> { where(status: [ :pending, :provisioning, :ready, :running ]) }
    scope :for_agent, ->(agent) { where(agent_id: agent) }
    scope :expired_sessions, -> { where(expires_at: ...Time.current) }

    def catalog_entry
      CodeAgentCatalog.find(tool)
    end

    def tool_name
      CodeAgentCatalog.display_name(tool)
    end

    def expired_by_time?
      expires_at.present? && expires_at <= Time.current
    end

    def active?
      %w[pending provisioning ready running].include?(status) && !expired_by_time?
    end

    # A run needs a sandbox that exists and has not aged out. A completed or
    # failed session still has its container, so a follow-up prompt is one
    # more run rather than a new sandbox.
    def can_run?
      %w[ready completed failed].include?(status) && !expired_by_time?
    end

    def github_access?
      github_access != "none"
    end

    # Appends a progress event, in the shape AgentRun#append_event uses so
    # both timelines render the same way. update_column: no validations or
    # callbacks, and it reads current database state first, so an event
    # emitted from a job thread cannot lose one written beside it.
    def append_event(kind:, label:, status: "done", detail: nil, duration_ms: nil)
      event = {
        "at" => Time.current.iso8601(3),
        "eid" => "#{id}-#{SecureRandom.hex(3)}",
        "kind" => kind.to_s,
        "label" => label.to_s,
        "status" => status.to_s
      }
      event["detail"] = detail.to_s.byteslice(0, 1200).to_s.scrub if detail.present?
      event["duration_ms"] = duration_ms if duration_ms
      current = self.class.where(id: id).pick(:events) || []
      current = [] unless current.is_a?(Array)
      update_column(:events, current + [ event ])
      event
    end

    def brief
      value = super
      value.is_a?(Hash) ? value : {}
    end

    def events
      value = super
      value.is_a?(Array) ? value : []
    end

    def needs_count = Array(brief["needs"]).size

    def limitations_count = Array(brief["limitations"]).size

    def runtime_ms
      return nil if started_at.blank?

      finished = completed_at || last_activity_at
      return nil if finished.blank?

      ((finished - started_at) * 1000).round
    end

    # What the dashboard lists and polls. Deliberately carries no token, no
    # state path and no credential value: the brief's own credential fields
    # are environment variable names only (CodeSessionBrief).
    def as_json_summary
      {
        id: id,
        session_id: session_id,
        status: status,
        tool: tool,
        tool_name: tool_name,
        backend: backend,
        agent: agent && { id: agent.id, name: agent.name, slug: agent.slug },
        evaluation_run_id: evaluation_run_id,
        repository: repository,
        branch: branch,
        github_access: github_access,
        network_mode: network_mode,
        model: model,
        task: task,
        container_id: container_id,
        exit_code: exit_code,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cost: cost&.to_f,
        error_message: error_message,
        needs_count: needs_count,
        limitations_count: limitations_count,
        runtime_ms: runtime_ms,
        started_at: started_at&.iso8601,
        completed_at: completed_at&.iso8601,
        last_activity_at: last_activity_at&.iso8601,
        expires_at: expires_at&.iso8601,
        created_at: created_at&.iso8601
      }
    end

    # Stores a transcript, capped and scrubbed so one runaway build log
    # cannot make the row unreadable.
    def transcript=(value)
      super(value.nil? ? nil : value.to_s.byteslice(0, MAX_TRANSCRIPT_BYTES).to_s.scrub)
    end

    private

    def generate_session_id
      self.session_id ||= SecureRandom.uuid
    end

    # Accepts what a person actually pastes: a browser URL, a clone URL, an
    # ssh remote, or owner/repo. Anything else is left alone for the format
    # validation to reject with a message that names the shape wanted.
    def normalize_repository
      return if repository.blank?

      value = repository.to_s.strip
      value = value.delete_prefix("git@github.com:")
      value = value.sub(%r{\Ahttps?://(?:www\.)?github\.com/}i, "")
      value = value.sub(%r{\Agithub\.com/}i, "")
      value = value.delete_suffix(".git").delete_suffix("/")
      self.repository = value
    end

    def branch_has_no_parent_traversal
      return if branch.blank?

      errors.add(:branch, "is not a valid branch name") if branch.include?("..") || branch.end_with?("/", ".", ".lock")
    end

    def backend_registered
      return if backend.blank?

      return if CodeSessionOrchestrator.backends.key?(backend.to_s)

      errors.add(:backend, "is not a registered code session backend")
    end

    def set_expiration
      minutes = ActionAgent.code_session_limits[:session_duration_minutes].to_i
      self.expires_at ||= minutes.minutes.from_now
    end
  end
end
