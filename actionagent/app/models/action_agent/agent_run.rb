# frozen_string_literal: true

module ActionAgent
  class AgentRun < ApplicationRecord
    belongs_to :agent
    # The version of the agent this run executed under — the latest at the
    # time, since a run is against the agent as it is.
    belongs_to :agent_version, optional: true
    before_create { self.agent_version_id ||= agent&.latest_version&.id }
    has_many :input_requests, as: :subject, inverse_of: :subject, dependent: :destroy
    has_many :pending_input_requests, -> { pending.for_listing.order(:id) },
      class_name: "ActionAgent::InputRequest", as: :subject, inverse_of: :subject

    # Raised when a caller hands a run files to attach in a host app that
    # has nowhere to keep them.
    class AttachmentsUnavailable < StandardError
      def initialize(message = "Attachments need Active Storage in the host app (run `rails active_storage:install`)")
        super
      end
    end

    # Files uploaded with the run. The execution service delivers them to
    # the model (images and PDFs as data URIs, text inlined) and the
    # persisted user message keeps a manifest of them.
    #
    # Guarded like RecordingSnapshot: a host app created with
    # --skip-active-storage has no has_many_attached to call.
    has_many_attached :attachments if defined?(ActiveStorage)

    # The key the caller's identity is recorded under in +input_params+.
    # Underscored so it cannot collide with a provider override, and
    # stripped from anything a client sends (see Api::AgentsController).
    ACTOR_PARAM = "_actor_gid"
    # The key a checkout sandbox's app runtime this one run also reaches is
    # recorded under ("sandbox:<session_id>"; never its token). Set only by
    # the server, after it checked the caller owns that sandbox, and
    # stripped from anything a client sends, as the actor is.
    SANDBOX_PARAM = "_sandbox_server"
    # The key of that sandbox's browser ("browser:<session_id>"), recorded
    # when the browser was running as the run was created, so a run whose
    # browser stops before it executes fails rather than running without
    # it. Set and stripped like SANDBOX_PARAM.
    BROWSER_PARAM = "_sandbox_browser"

    # +input_params+ with the caller recorded alongside them.
    #
    # The actor is stored as a Global ID rather than as the record, so the
    # worker that picks the run up — on another machine, minutes later —
    # authorizes as the same person who asked for the run. A caller the host
    # cannot address that way (a plain object, a service account) is simply
    # not recorded: the run then executes unattributed, which a host scope
    # reads as "no access", rather than executing as somebody else.
    #
    # @param params [Hash] the run's own parameters
    # @param actor [Object, nil] the caller
    # @return [Hash]
    def self.params_with_actor(params, actor)
      params = (params || {}).to_h.except(ACTOR_PARAM, ACTOR_PARAM.to_sym, SANDBOX_PARAM, SANDBOX_PARAM.to_sym,
        BROWSER_PARAM, BROWSER_PARAM.to_sym)
      gid = actor.respond_to?(:to_global_id) ? actor.to_global_id.to_s : nil
      gid ? params.merge(ACTOR_PARAM => gid) : params
    rescue StandardError => e
      Rails.logger.warn("[AgentRun] could not record the run's actor: #{e.class} - #{e.message}")
      params
    end

    # The caller this run executes on behalf of.
    #
    # Set in memory for a synchronous run; rehydrated from the stored Global
    # ID for one picked up by a worker. A Global ID that no longer resolves
    # (the user was deleted) yields nil, so the run loses access rather than
    # inheriting someone else's.
    # @return [Object, nil]
    def actor
      return @actor if defined?(@actor)

      @actor = locate_actor
    end

    attr_writer :actor

    # The "sandbox:<session_id>" runtime this run reaches beside the agent's
    # own MCP servers, or nil.
    # @return [String, nil]
    def sandbox_server_key
      key = input_params[SANDBOX_PARAM] if input_params.is_a?(Hash)
      key.to_s.presence if SandboxSession.runtime_server_key?(key)
    end

    # The session id of that sandbox, for a summary.
    def sandbox_id
      sandbox_server_key&.delete_prefix(SandboxSession::RUNTIME_SERVER_PREFIX)
    end

    # The "browser:<session_id>" key of that sandbox's browser, when it was
    # running as the run was created, or nil.
    # @return [String, nil]
    def browser_server_key
      key = input_params[BROWSER_PARAM] if input_params.is_a?(Hash)
      key.to_s.presence if sandbox_server_key && SandboxSession.browser_server_key?(key)
    end

    # Whether this run knows who it is for. A run with a recorded actor that
    # no longer resolves is *not* unattributed — it is broken, and callers
    # that care can tell the two apart.
    # @return [Boolean]
    def actor_recorded?
      input_params.is_a?(Hash) && input_params[ACTOR_PARAM].present?
    end

    # Whether runs can carry files in this host app: Active Storage loaded,
    # the macro applied, and its tables migrated. Never raises — a host
    # that skipped `rails active_storage:install` still runs agents, it
    # just can't attach files to them.
    def self.attachments_available?
      defined?(ActiveStorage) && method_defined?(:attachments) && ActiveStorage::Blob.table_exists?
    rescue StandardError
      false
    end

    # How an attachment reaches the model, by MIME type with a filename
    # fallback for the text formats browsers upload as octet-stream:
    # images and documents ride along as data URIs, text is inlined into
    # the prompt, anything else is only described.
    TEXT_CONTENT_TYPES = %w[application/json application/xml application/x-yaml application/csv].freeze
    TEXT_EXTENSIONS = %w[.csv .md .txt .json .yml .yaml].freeze

    def self.attachment_kind(content_type, filename = nil)
      type = content_type.to_s.downcase
      return "image" if type.start_with?("image/")
      return "document" if type == "application/pdf"
      return "text" if type.start_with?("text/") || TEXT_CONTENT_TYPES.include?(type)
      return "text" if TEXT_EXTENSIONS.include?(File.extname(filename.to_s).downcase)

      "file"
    end

    # `awaiting_input` is a run paused until a person answers its
    # InputRequests; AgentResumeJob continues it.
    enum :status, { pending: 0, running: 1, complete: 2, failed: 3, cancelled: 4, awaiting_input: 5 }

    # Validations
    validates :trace_id, presence: true

    # Scopes
    scope :recent, -> { order(created_at: :desc) }
    scope :successful, -> { where(status: :complete) }
    scope :failed_runs, -> { where(status: :failed) }
    scope :today, -> { where("created_at >= ?", Time.current.beginning_of_day) }

    # Callbacks
    before_validation :set_trace_id, on: :create
    after_update_commit :broadcast_update, if: :saved_change_to_status?

    # Add a log entry
    def add_log(message, level: :info)
      new_logs = logs || []
      new_logs << {
        timestamp: Time.current.iso8601,
        level: level.to_s,
        message: message
      }
      update!(logs: new_logs)
    end

    # Appends a progress event to logs mid-run so pollers can stream what the
    # agent is doing (pending llm/tool/agent calls). Events pair up by eid:
    # a "started" event is pending until a "done"/"error" with the same eid
    # lands. update_column: no validations/callbacks, safe from the run's own
    # execution thread; reads current DB state so add_log interleaves safely.
    def append_event(eid:, kind:, label:, status: "done", detail: nil, duration_ms: nil)
      event = {
        "at" => Time.current.iso8601(3),
        "eid" => eid,
        "kind" => kind.to_s,
        "label" => label.to_s,
        "status" => status.to_s
      }
      event["detail"] = detail.to_s.byteslice(0, 1200).to_s.scrub if detail
      event["duration_ms"] = duration_ms if duration_ms
      current = self.class.where(id: id).pick(:logs) || []
      update_column(:logs, current + [ event ])
      event
    end

    # Stable short fingerprint of the instructions this run executed under —
    # the grouping key (with model) for configuration cohorts when comparing
    # instruction/model changes.
    def instructions_digest
      instructions = output_metadata&.dig("instructions")
      return nil if instructions.blank?

      Digest::SHA256.hexdigest(instructions).first(8)
    end

    # Deterministic memorable name for the digest ("calm-heron") — reads far
    # better than hex when comparing cohorts, and is stable across runs and
    # deployments because it's derived from the digest alone.
    CODENAME_ADJECTIVES = %w[
      calm brisk quiet bold amber coral dusky fresh golden keen
      lively mellow nimble pale rustic silver tidal vivid wry zesty
      arid breezy crisp dapper eager foggy hazy icy jolly lunar
      misty polar
    ].freeze
    CODENAME_NOUNS = %w[
      heron otter falcon cedar willow harbor mesa ridge grove delta
      prairie summit canyon reef atoll fjord tundra oasis lagoon dune
      glacier meadow bluff cove marsh basin knoll strait quarry vale
      hollow crag
    ].freeze

    def instructions_codename
      digest = instructions_digest
      return nil unless digest

      value = digest.to_i(16)
      "#{CODENAME_ADJECTIVES[value % 32]}-#{CODENAME_NOUNS[(value / 32) % 32]}"
    end

    # Calculate duration if not set
    def calculated_duration_ms
      return duration_ms if duration_ms.present?
      return nil unless started_at && completed_at

      ((completed_at - started_at) * 1000).to_i
    end

    # Check if run is still in progress
    def in_progress?
      pending? || running?
    end

    # Check if run is finished
    def finished?
      complete? || failed? || cancelled?
    end

    # The conversation this run belongs to: the one it actually wrote to
    # once it has executed (output_metadata), else the one the caller asked
    # to continue. A pinned id the run declined — another agent's context,
    # or another action's — must not be the id the API reports, or the
    # runner would open a conversation the turn is not in.
    def context_id
      output_metadata&.dig("context_id") || input_params&.dig("context_id")
    end

    # The run's files as the runner and the persisted user message show
    # them: one hash per attachment, with the kind the execution service
    # sorted it into and a blob URL for thumbnails (nil when the host app
    # didn't draw Active Storage's routes). Empty without Active Storage.
    def attachment_manifest
      return [] unless self.class.attachments_available?

      attachment_records.map do |attachment|
        blob = attachment.blob
        {
          "id" => attachment.id,
          "blob_id" => blob.id,
          "signed_id" => blob.signed_id,
          "filename" => blob.filename.to_s,
          "content_type" => blob.content_type,
          "byte_size" => blob.byte_size,
          "kind" => self.class.attachment_kind(blob.content_type, blob.filename.to_s),
          "url" => blob_path(blob)
        }
      end
    end

    # Get a summary for display
    def summary
      {
        id: id,
        status: status,
        input_preview: input_prompt&.truncate(100),
        output_preview: output&.truncate(200),
        duration_ms: calculated_duration_ms,
        tokens: total_tokens,
        provider: output_metadata&.dig("provider"),
        model: output_metadata&.dig("model"),
        action_name: action_name || output_metadata&.dig("action") || "ask",
        instructions_digest: instructions_digest,
        instructions_codename: instructions_codename,
        instructions_preview: output_metadata&.dig("instructions")&.truncate(120),
        attachments: attachment_manifest,
        context_id: context_id,
        sandbox_id: sandbox_id,
        created_at: created_at,
        error: error_message
      }
    end

    # Tells subscribers of this run's stream, and of its agent's, that the
    # run's status changed.
    def broadcast_update
      LiveUpdates.broadcast("agent_run_#{id}", type: "update", id: id, status: status)
      LiveUpdates.broadcast("agent_runs_#{agent_id}", type: "update", id: id, status: status)
    end

    # Cancels a run that is in progress or waiting for input, and every
    # request for input it still has pending.
    #
    # @param reason [String] recorded as the run's error message
    def cancel!(reason = "Cancelled by user")
      return unless in_progress? || awaiting_input?

      transaction do
        update!(status: :cancelled, completed_at: Time.current, error_message: reason)
        input_requests.pending.update_all(status: InputRequest.statuses[:cancelled], updated_at: Time.current)
      end
      broadcast_update
    end

    # Expires the run's overdue requests for input, which fails the run (see
    # InputRequest#expire!). Returns the run, reloaded when a request
    # expired.
    def expire_overdue_input_requests!
      return self unless awaiting_input?

      InputRequest.expire_overdue!(input_requests).positive? ? reload : self
    end

    # Writes one execution segment's result: `complete` with its output, or,
    # for a generation that paused, `awaiting_input` with one InputRequest
    # per paused tool call, stored in the same transaction so an answer can
    # never find the requests before the run waits on them. Tokens and
    # duration add to what earlier segments of the run recorded.
    #
    # @param result [Hash] AgentExecutionService's result
    # @param segment_started_at [Time] when this segment started executing
    def record_result!(result, segment_started_at:)
      usage = result[:usage] || {}
      attributes = {
        output_metadata: result[:metadata],
        duration_ms: duration_ms.to_i + ((Time.current - segment_started_at) * 1000).to_i,
        input_tokens: add_tokens(input_tokens, usage[:input_tokens]),
        output_tokens: add_tokens(output_tokens, usage[:output_tokens]),
        total_tokens: add_tokens(total_tokens, usage[:total_tokens])
      }

      transaction do
        if result[:input_requests].present?
          InputRequest.record_pause!(self, result[:input_requests], checkpoint: result[:checkpoint])
          update!(attributes.merge(status: :awaiting_input))
        else
          update!(attributes.merge(output: result[:output], status: :complete, completed_at: Time.current))
        end
      end
    end

    # Fails the run with +error+, recording its class beside the message: the
    # class is what tells a refusal from a crash without reading prose.
    #
    # @param error [Exception]
    # @param message [String] the message to record, when it must differ from
    #   the error's own
    def record_failure!(error, message: error.message)
      update!(
        status: :failed,
        completed_at: Time.current,
        error_message: message,
        error_backtrace: error.backtrace&.first(10)&.join("\n"),
        output_metadata: output_metadata.to_h.merge("error_class" => error.class.name)
      )
    end

    # Yields under the run's row lock unless the run was cancelled meanwhile,
    # so a cancel that arrived while the run executed is never overwritten by
    # the result. Returns whether it yielded.
    def unless_cancelled
      with_lock do
        if cancelled?
          add_log("Execution finished after cancellation; result discarded", level: :info)
          next false
        end

        yield
        true
      end
    end

    private

    def add_tokens(recorded, segment)
      return recorded if segment.nil?

      recorded.to_i + segment.to_i
    end

    def locate_actor
      return nil unless actor_recorded?
      return nil unless defined?(GlobalID::Locator)

      GlobalID::Locator.locate(input_params[ACTOR_PARAM])
    rescue StandardError => e
      Rails.logger.warn("[AgentRun] could not resolve the run's actor: #{e.class} - #{e.message}")
      nil
    end

    def set_trace_id
      self.trace_id ||= SecureRandom.uuid
    end

    # Reads the association as loaded when a list preloaded it
    # (with_attachments below), so serializing a page of runs costs two
    # queries rather than two per run; a single run fetches its own.
    def attachment_records
      if attachments_attachments.loaded?
        attachments_attachments.sort_by(&:id)
      else
        attachments_attachments.includes(:blob).order(:id).to_a
      end
    end

    # Preloads attachments and blobs for a list of runs — a no-op scope in
    # a host without Active Storage, so callers need no guard of their own.
    def self.with_attachments
      attachments_available? ? with_attached_attachments : all
    end

    def blob_path(blob)
      Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
    rescue StandardError
      nil
    end
  end
end
