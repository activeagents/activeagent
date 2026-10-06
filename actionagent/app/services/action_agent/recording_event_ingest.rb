# frozen_string_literal: true

module ActionAgent
  # Used to store a batch of events a browser posted to a session recording.
  #
  # A batch is a JSON object:
  #
  #   {
  #     "sent_at": 1767225600000,
  #     "recording_events": [
  #       { "kind": "rrweb", "timestamp": 1767225599500, "data": { "type": 3, "data": {} } },
  #       { "kind": "console", "timestamp": 1767225599800, "data": { "level": "error", "message": "boom" } }
  #     ]
  #   }
  #
  # `sent_at` is the client's clock when it sent the batch, and `timestamp`
  # the client's clock when the event happened, both in epoch milliseconds
  # (`sent_at` may also be ISO 8601). The batch's clock offset, receive time
  # minus `sent_at`, is added to every timestamp, so a batch from a client
  # whose clock is wrong is still stored in server time. An event without a
  # timestamp is placed at `sent_at`. A timestamp more than EVENT_WINDOW_BEFORE
  # before `sent_at`, or more than EVENT_WINDOW_AFTER after it, refuses the
  # batch.
  #
  # The batch is stored whole or not at all. RecordingEvent.limits caps it,
  # and caps the recording's totals. A refused batch over a cap is counted
  # in the recording's dropped_event_count.
  #
  # Given +secrets+, every string in the batch's events has each of them
  # masked (SecretScrubber) before it is stored.
  class RecordingEventIngest
    # The outcome as an HTTP response: +status+ and the JSON +body+.
    Result = Struct.new(:status, :body, keyword_init: true)

    PAYLOAD_TOO_LARGE = 413

    # The key a batch carries its events under. The engine's filter_parameters
    # initializer keeps it out of request logs, so it is a name no host
    # parameter is likely to share.
    BATCH_KEY = "recording_events"

    EVENT_WINDOW_BEFORE = 24.hours
    EVENT_WINDOW_AFTER = 1.minute
    # 1970 through the end of 9999, in epoch milliseconds: what every
    # supported database can store.
    SENT_AT_RANGE = (0..253_402_300_799_999).freeze

    # @param recording [SessionRecording] the recording the batch was posted to
    # @param body [String] the request body
    # @param kinds [Array<String>] the event kinds the caller may write
    # @param secrets [Array<String>] values to mask in the events
    # @return [Result]
    def self.call(recording, body, received_at: Time.current, kinds: RecordingEvent::CLIENT_KINDS, secrets: [])
      new(recording, body, received_at: received_at, kinds: kinds, secrets: secrets).call
    end

    def initialize(recording, body, received_at:, kinds:, secrets: [])
      @recording = recording
      @body = body.to_s
      @received_at = received_at
      @kinds = kinds.map(&:to_s)
      @secrets = secrets
    end

    def call
      batch = parse_body
      return invalid("The batch nests deeper than #{RecordingEvent::MAX_NESTING} levels") if batch == :too_deep

      events = batch.is_a?(Hash) ? batch[BATCH_KEY] : nil
      return invalid("The body must be a JSON object with a non-empty #{BATCH_KEY} array") unless events.is_a?(Array) && events.any?

      limits = RecordingEvent.limits
      if events.size > limits[:batch_events] || @body.bytesize > limits[:batch_bytes]
        return too_large(events.size, "The batch is over the limit of #{limits[:batch_events]} events or #{limits[:batch_bytes]} bytes")
      end

      sent_at = epoch_milliseconds(batch["sent_at"])
      return invalid("sent_at must be the client's send time, in epoch milliseconds or ISO 8601") unless sent_at

      problem = event_problem(events, sent_at)
      return invalid(problem) if problem

      offset = RecordingEvent.milliseconds(@received_at) - sent_at
      store(build_rows(SecretScrubber.scrub(events, @secrets), sent_at, offset), offset, limits)
    end

    private

    # The parsed body, :too_deep when it nests past RecordingEvent::MAX_NESTING,
    # or nil when it is not JSON.
    def parse_body
      RecordingEvent.parse_json(@body)
    rescue JSON::NestingError
      :too_deep
    rescue JSON::ParserError
      nil
    end

    # Why +events+ cannot be stored, or nil when they can.
    def event_problem(events, sent_at)
      return "Every event must be a JSON object" unless events.all?(Hash)

      refused = events.map { |event| event["kind"].to_s.presence || "(missing)" }.uniq - @kinds
      return "Event kinds not accepted here: #{refused.join(', ')}. Accepted: #{@kinds.join(', ')}" if refused.any?

      return "An event timestamp must be epoch milliseconds" unless events.all? { |event| event["timestamp"].nil? || event["timestamp"].is_a?(Numeric) }

      window = (sent_at - EVENT_WINDOW_BEFORE.in_milliseconds)..(sent_at + EVENT_WINDOW_AFTER.in_milliseconds)
      unless events.all? { |event| event["timestamp"].nil? || window.cover?(event["timestamp"]) }
        return "An event timestamp must be within #{EVENT_WINDOW_BEFORE.inspect} before sent_at and #{EVENT_WINDOW_AFTER.inspect} after it"
      end

      nil
    end

    # One unsaved row per kind, holding that kind's events in batch order.
    def build_rows(events, sent_at, offset)
      grouped = {}
      events.each_with_index do |event, index|
        group = (grouped[event["kind"].to_s] ||= { index: index, events: [] })
        client_time = event["timestamp"] || sent_at
        group[:events] << { "at" => client_time.floor + offset, "data" => event["data"] }
      end

      grouped.map do |kind, group|
        row = RecordingEvent.new(session_recording: @recording, kind: kind, batch_index: group[:index], clock_offset_ms: offset)
        row.events = group[:events]
        row
      end
    end

    def store(rows, offset, limits)
      count = rows.sum(&:event_count)
      bytes = rows.sum(&:byte_size)
      outcome = nil

      @recording.with_lock do
        outcome =
          if !@recording.recording?
            :finished
          elsif @recording.event_count + count > limits[:recording_events] || @recording.event_bytes + bytes > limits[:recording_bytes]
            :over_cap
          else
            rows.each(&:save!)
            @recording.update_columns(event_count: @recording.event_count + count, event_bytes: @recording.event_bytes + bytes)
            :stored
          end
      end

      case outcome
      when :finished then invalid("Recording already completed")
      when :over_cap
        too_large(count, "The recording is over the limit of #{limits[:recording_events]} events or #{limits[:recording_bytes]} bytes")
      else
        Result.new(status: :created, body: { stored: count, clock_offset_ms: offset })
      end
    end

    # +value+ in epoch milliseconds, or nil when it is not a time in
    # SENT_AT_RANGE.
    def epoch_milliseconds(value)
      milliseconds =
        case value
        when Numeric then value.floor if value.finite?
        when String then RecordingEvent.milliseconds(Time.iso8601(value))
        end
      milliseconds if SENT_AT_RANGE.cover?(milliseconds)
    rescue ArgumentError
      nil
    end

    def invalid(message)
      Result.new(status: :unprocessable_entity, body: { error: message })
    end

    def too_large(dropped, message)
      SessionRecording.update_counters(@recording.id, dropped_event_count: dropped)
      Result.new(status: PAYLOAD_TOO_LARGE, body: { error: message, code: "recording_limit", dropped: dropped })
    end
  end
end
