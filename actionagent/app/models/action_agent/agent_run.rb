# frozen_string_literal: true

module ActionAgent
  class AgentRun < ApplicationRecord
    belongs_to :agent

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

    # Status enum
    enum :status, { pending: 0, running: 1, complete: 2, failed: 3, cancelled: 4 }

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

    # The conversation the caller pinned this run to (input_params), if any.
    def context_id
      input_params&.dig("context_id")
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
        created_at: created_at,
        error: error_message
      }
    end

    # Stream output updates via ActionCable
    def broadcast_update
      payload = { type: "update", run: summary }
      ActionCable.server.broadcast("agent_run_#{id}", payload)
      ActionCable.server.broadcast("agent_runs_#{agent_id}", payload)
    end

    # Cancel a running execution
    def cancel!
      return unless in_progress?

      update!(
        status: :cancelled,
        completed_at: Time.current,
        error_message: "Cancelled by user"
      )
      broadcast_update
    end

    private

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
