# frozen_string_literal: true

module ActionAgent
  class SessionRecording < ApplicationRecord
    include Ownable
    owned_by :user, :account

    belongs_to :agent_run, optional: true
    belongs_to :sandbox_session, optional: true
    # The conversation a recording belongs to. A recording of a conversation
    # outlives any one of its runs.
    belongs_to :agent_context, optional: true

    has_many :recording_actions, dependent: :destroy
    has_many :recording_snapshots, dependent: :destroy
    has_many :recording_events, dependent: :destroy

    enum :status, { recording: 0, completed: 1, failed: 2 }

    # Where a recording came from: an agent's browser, or a person using the
    # dashboard. Recordings made before this was recorded have none.
    SOURCES = %w[agent dashboard].freeze

    # Browser state that must never leave the server in a read response: the
    # handoff state a recording carries is a copy of the visitor's cookies
    # and web storage. Only the handoff endpoint returns it, to the owner,
    # when they continue the session.
    SENSITIVE_STATE_KEYS = %w[cookies session_storage local_storage].freeze

    INGEST_TOKEN_PREFIX = "aarec_"
    INGEST_TOKEN_TTL = 2.hours

    validates :status, presence: true
    validates :source, inclusion: { in: SOURCES }, allow_nil: true
    validate :must_have_parent, unless: -> { demo_recording? || user_session? }

    scope :recent, -> { order(created_at: :desc) }
    scope :for_agent, ->(agent_id) { joins(:agent_run).where(agent_runs: { agent_id: agent_id }) }
    scope :demo, -> { where(name: "lander_demo") }
    scope :user_sessions, -> { where("name LIKE ?", "user_takeover_%") }

    # Check if this is a demo recording (doesn't require parent)
    def demo_recording?
      name&.start_with?("lander_") || name == "demo"
    end

    # Check if this is a user takeover session (doesn't require parent)
    def user_session?
      name&.start_with?("user_takeover_")
    end

    # Start a new recording session.
    #
    # The owner column is written here, at creation: the index and recent
    # endpoints scope through it, and a recording nothing ever stamped was
    # invisible in the list to the very person who made it. An explicit
    # +owner+ wins; otherwise the recording inherits the owner of the sandbox,
    # agent or conversation it records. Ownable#owner= is a no-op in a
    # single-user install, where nothing is owned.
    def self.start!(agent_run: nil, sandbox_session: nil, agent_context: nil, source: nil, name: nil, owner: nil)
      recording = new(
        agent_run: agent_run,
        sandbox_session: sandbox_session,
        agent_context: agent_context,
        source: source,
        name: name || generate_name(agent_run, sandbox_session, agent_context),
        status: :recording,
        metadata: { started_at: Time.current.iso8601 }
      )
      recording.owner = owner || inherited_owner(agent_run, sandbox_session, agent_context)
      recording.save!
      recording
    end

    # Start a user takeover session (for lander demo analytics)
    def self.start_user_session!(visitor_id: nil, parent_demo_id: nil, page_url: nil, owner: nil)
      recording = new(
        name: "user_takeover_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{SecureRandom.hex(4)}",
        status: :recording,
        metadata: {
          started_at: Time.current.iso8601,
          session_type: "user_takeover",
          visitor_id: visitor_id,
          parent_demo_id: parent_demo_id,
          page_url: page_url,
          user_agent: nil # Will be set from request
        }
      )
      recording.owner = owner
      recording.save!
      recording
    end

    # Whoever owns the sandbox, agent or conversation's agent a recording is
    # made against. Both models declare the same owner candidates as this
    # one, so the record they hand back is of the class this install owns
    # things through.
    def self.inherited_owner(agent_run, sandbox_session, agent_context = nil)
      conversation_agent = agent_context&.contextable
      sandbox_session&.owner || agent_run&.agent&.owner || (conversation_agent.owner if conversation_agent.is_a?(Agent))
    end

    # The digest an ingest token is stored and looked up as.
    def self.ingest_token_digest(token)
      Digest::SHA256.hexdigest(token.to_s)
    end

    # Issues the token a browser posts this recording's events with, and
    # returns it. Only its digest is stored, and issuing another replaces it.
    # The token expires after +expires_in+, or when the recording's sandbox
    # does if that is sooner. See #ingest_token_valid? for when it is
    # accepted.
    # @return [String]
    def issue_ingest_token!(expires_in: INGEST_TOKEN_TTL)
      token = "#{INGEST_TOKEN_PREFIX}#{SecureRandom.base58(32)}"
      expires_at = [ Time.current + expires_in, sandbox_session&.expires_at ].compact.min
      update!(ingest_token_digest: self.class.ingest_token_digest(token), ingest_token_expires_at: expires_at)
      token
    end

    # Whether +token+ may post events to this recording now: it is the token
    # last issued for this recording, it has not expired, the recording is
    # still recording, and the recording's sandbox, if it has one, is active.
    def ingest_token_valid?(token)
      return false if token.blank? || ingest_token_digest.blank?
      return false unless recording? && ingest_token_expires_at&.future?
      return false if sandbox_session_id && !sandbox_live?

      ActiveSupport::SecurityUtils.secure_compare(ingest_token_digest, self.class.ingest_token_digest(token))
    end

    # Stores one event the server observed, such as an agent's browser
    # action, and counts it. Unlike a browser's batches, server events are
    # not capped.
    # @param data [Hash] the event
    # @param started_at [Time] when it began
    # @param finished_at [Time] when it ended
    # @return [RecordingEvent]
    def record_server_event!(kind:, data:, started_at:, finished_at: started_at)
      event = recording_events.new(kind: kind, clock_offset_ms: 0)
      event.events = [ { "at" => RecordingEvent.milliseconds(started_at), "data" => data } ]
      event.occurred_to = [ finished_at, event.occurred_from ].max
      event.save!
      self.class.update_counters(id, event_count: 1, event_bytes: event.byte_size)
      event
    end

    # Record a browser action
    def record_action!(action_type:, selector: nil, value: nil, screenshot: nil, dom_snapshot: nil, metadata: {})
      raise "Recording already completed" unless recording?

      action = recording_actions.create!(
        action_type: action_type,
        sequence: next_sequence,
        timestamp_ms: elapsed_ms,
        selector: selector,
        value: value,
        metadata: metadata
      )

      # Handle screenshot attachment if provided
      if screenshot.present?
        snapshot = store_snapshot(screenshot, :screenshot, action)
        action.update!(screenshot_key: snapshot.storage_key)
      end

      # Handle DOM snapshot if provided
      if dom_snapshot.present?
        snapshot = store_snapshot(dom_snapshot, :dom, action)
        action.update!(dom_snapshot_key: snapshot.storage_key)
      end

      increment!(:action_count)
      action
    end

    # Complete the recording
    def complete!
      return unless recording?

      update!(
        status: :completed,
        duration_ms: elapsed_ms,
        metadata: metadata.merge(completed_at: Time.current.iso8601)
      )
    end

    # Mark recording as failed
    def fail!(error_message = nil)
      return unless recording?

      update!(
        status: :failed,
        duration_ms: elapsed_ms,
        metadata: metadata.merge(
          failed_at: Time.current.iso8601,
          error: error_message
        )
      )
    end

    # Get timeline data for playback. Values and metadata go through the
    # same redaction the /actions endpoint applies: this is what #show
    # renders, and it used to hand back the cleartext password that
    # /actions had just redacted for the same action.
    def timeline
      recording_actions.order(:sequence).map do |action|
        {
          id: action.id,
          type: action.action_type,
          sequence: action.sequence,
          timestamp_ms: action.timestamp_ms,
          selector: action.selector,
          value: action.redacted_value,
          screenshot_key: action.screenshot_key,
          metadata: action.safe_metadata
        }
      end
    end

    private

    def sandbox_live?
      live = SandboxSession.active.where(id: sandbox_session_id)
      live.where(expires_at: nil).or(live.where(expires_at: Time.current..)).exists?
    end

    def must_have_parent
      return if agent_run.present? || sandbox_session.present? || agent_context.present?

      errors.add(:base, "must belong to an agent_run, sandbox_session or agent_context")
    end

    def self.generate_name(agent_run, sandbox_session, agent_context = nil)
      prefix = if agent_run&.agent
        agent_run.agent.name.parameterize
      elsif sandbox_session&.agent_template
        sandbox_session.agent_template.name.parameterize
      elsif agent_context&.agent_name.present?
        agent_context.agent_name.parameterize
      else
        "session"
      end

      "#{prefix}_#{Time.current.strftime('%Y%m%d_%H%M%S')}"
    end

    def next_sequence
      (recording_actions.maximum(:sequence) || 0) + 1
    end

    def elapsed_ms
      ((Time.current - created_at) * 1000).to_i
    end

    def store_snapshot(data, snapshot_type, action = nil)
      storage_key = generate_storage_key(snapshot_type, action&.sequence)

      # For now, store metadata - actual file upload handled by service
      recording_snapshots.create!(
        recording_action: action,
        storage_key: storage_key,
        snapshot_type: snapshot_type,
        file_size_bytes: data.bytesize
      )
    end

    def generate_storage_key(snapshot_type, sequence = nil)
      parts = [ "recordings", id, snapshot_type.to_s ]
      parts << sequence.to_s if sequence
      parts << SecureRandom.hex(8)
      parts.join("/")
    end
  end
end
