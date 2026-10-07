# frozen_string_literal: true

module ActionAgent
  # A batch of one kind of event that a browser recorded during a session.
  #
  # Kinds:
  #   rrweb        DOM snapshots and mutations from the rrweb recorder
  #   action       an agent's browser tool call, written by MCPRecordingMiddleware
  #   console      a console line from the recorded page
  #   marker       a label a recorder placed on the timeline
  #   human_input  input a person relayed while taking over a browser
  #
  # Each event in a row is a Hash of "at", its server time in epoch
  # milliseconds, and "data", what the recorder sent. A browser's events are
  # stored in server time: the client's timestamp plus the clock offset of the
  # batch they arrived in. Rows are ordered by occurred_from, batch_index, id.
  #
  # The payload is the row's events as gzip JSON. A payload up to
  # INLINE_PAYLOAD_LIMIT compressed bytes is kept in the row. A larger one is
  # attached through Active Storage when the host has it, and kept in the row
  # otherwise.
  class RecordingEvent < ApplicationRecord
    include Ownable
    owned_by :account, :user

    KINDS = %w[rrweb action console marker human_input].freeze
    # The kinds a browser may post. The server writes the others.
    CLIENT_KINDS = %w[rrweb console marker].freeze

    # See ActionAgent.recording_limits.
    DEFAULT_LIMITS = {
      batch_events: 1_000,
      batch_bytes: 1.megabyte,
      recording_events: 100_000,
      recording_bytes: 100.megabytes
    }.freeze

    INLINE_PAYLOAD_LIMIT = 64.kilobytes

    # How deep a batch's JSON may nest. An rrweb full snapshot nests two
    # levels per DOM element, so an ordinary page passes the JSON gem's
    # default of 100.
    MAX_NESTING = 512

    belongs_to :session_recording

    # Per ActionAgent.active_storage, like RecordingSnapshot: the gem depends
    # on railties, not rails, so a host may have no Active Storage at all, or
    # may switch attachments off.
    has_one_attached :payload_file, **ActionAgent.attachment_options if ActionAgent.active_storage_macros?

    validates :kind, inclusion: { in: KINDS }
    validates :occurred_from, :occurred_to, presence: true

    before_validation :copy_owner_from_recording, on: :create

    scope :chronological, -> { order(:occurred_from, :batch_index, :id) }

    # The caps in force: DEFAULT_LIMITS with ActionAgent.recording_limits
    # merged over them.
    # @return [Hash{Symbol => Integer}]
    def self.limits
      DEFAULT_LIMITS.merge((ActionAgent.recording_limits || {}).to_h.symbolize_keys)
    end

    # Whether payloads can be attached in this host app: Active Storage on
    # per ActionAgent.active_storage, the macro applied, and its tables
    # migrated.
    def self.attachments_available?
      ActionAgent.active_storage_available? && method_defined?(:payload_file)
    end

    # Parses JSON text nested up to MAX_NESTING levels.
    def self.parse_json(text)
      JSON.parse(text, max_nesting: MAX_NESTING)
    end

    # Returns +value+ as JSON text at any depth. Responses that carry event
    # data are generated with it: the default encoder refuses more than 100
    # levels, and event data was parsed with a limit of MAX_NESTING.
    def self.generate_json(value)
      JSON.generate(value.as_json, max_nesting: false)
    end

    # Converts epoch milliseconds to a Time.
    def self.time_at(milliseconds)
      Time.zone.at(milliseconds.to_r / 1000)
    end

    # Converts a Time to epoch milliseconds.
    def self.milliseconds(time)
      (time.to_r * 1000).floor
    end

    # The row's events, decoded. Empty when the payload cannot be read.
    # @return [Array<Hash>]
    def events
      @events ||= begin
        compressed = payload.nil? || payload.empty? ? attached_payload : payload
        compressed ? self.class.parse_json(ActiveSupport::Gzip.decompress(compressed)) : []
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] recording event #{id} payload unreadable: #{e.class}: #{e.message}")
        []
      end
    end

    # Stores +list+ as the payload and sets the counts and the time range
    # from it. Each entry is a Hash with an "at" in epoch milliseconds.
    def events=(list)
      json = self.class.generate_json(list)
      compressed = ActiveSupport::Gzip.compress(json)
      times = list.map { |event| event["at"].to_i }

      self.event_count = list.size
      self.byte_size = json.bytesize
      self.occurred_from = self.class.time_at(times.min || 0)
      self.occurred_to = self.class.time_at(times.max || 0)

      if compressed.bytesize > INLINE_PAYLOAD_LIMIT && self.class.attachments_available?
        self.payload = nil
        payload_file.attach(io: StringIO.new(compressed), filename: "recording-events.json.gz", content_type: "application/gzip")
      else
        self.payload = compressed
      end

      @events = list
    end

    private

    def attached_payload
      return nil unless self.class.attachments_available? && payload_file.attached?

      payload_file.download
    end

    # Both owner columns, whichever one this install owns through.
    def copy_owner_from_recording
      return unless session_recording

      self.user_id = session_recording.user_id
      self.account_id = session_recording.account_id
    end
  end
end
