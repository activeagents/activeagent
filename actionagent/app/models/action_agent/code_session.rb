# frozen_string_literal: true

module ActionAgent
  # A headless Claude Code session run inside an app_runtime sandbox's
  # checkout: the prompt, the stream-json transcript as it arrived, the
  # outcome Claude Code reported, and the diff the session left in the
  # working tree.
  #
  # The transcript is scrubbed of the sandbox's secrets (its GitHub token and
  # Claude Code credential) before it is stored, and bounded: long strings
  # are truncated and events past MAX_EVENTS are counted rather than kept.
  class CodeSession < ApplicationRecord
    include Ownable
    owned_by :user, :account

    belongs_to :sandbox_session

    enum :status, { queued: 0, running: 1, succeeded: 2, failed: 3, cancelled: 4 }

    MAX_PROMPT_CHARACTERS = 20_000
    MAX_EVENTS = 1_000
    # Per string inside an event: tool results can be whole files.
    MAX_EVENT_STRING = 4_000
    MAX_DIFF_BYTES = 500_000

    validates :prompt, presence: true, length: { maximum: MAX_PROMPT_CHARACTERS }

    scope :recent, -> { order(created_at: :desc) }

    # JSON columns carry no default on MySQL or SQLite (see the migration).
    def events
      Array(super)
    end

    def finished?
      succeeded? || failed? || cancelled?
    end

    # The values that must never be stored: the checkout token and the
    # Claude Code credential this session ran with.
    def secrets
      spec = sandbox_session.checkout_spec rescue nil
      [ spec&.dig(:token), *sandbox_session.runtime_environment.values ].compact
    end

    # Appends one stream-json event, scrubbed and bounded. Past MAX_EVENTS
    # only the count grows, so a runaway session cannot grow the row without
    # limit.
    def append_event!(event, secrets: self.secrets)
      stored = truncate_strings(SecretScrubber.scrub(event.to_h, secrets))

      with_lock do
        list = events
        if list.size < MAX_EVENTS
          self.events = list + [ stored ]
        else
          self.dropped_events_count = dropped_events_count.to_i + 1
        end
        save!
      end
    end

    # Records Claude Code's final "result" event.
    def record_result!(event)
      usage = event["usage"].is_a?(Hash) ? event["usage"] : {}

      update!(
        result: event["result"].to_s.presence && SecretScrubber.scrub(event["result"].to_s, secrets).truncate(MAX_EVENT_STRING * 4),
        claude_session_id: event["session_id"],
        num_turns: event["num_turns"],
        duration_ms: event["duration_ms"],
        total_cost_usd: event["total_cost_usd"],
        input_tokens: usage["input_tokens"],
        output_tokens: usage["output_tokens"]
      )
    end

    def diff=(value)
      text = SecretScrubber.scrub(value.to_s, secrets)
      super(text.bytesize > MAX_DIFF_BYTES ? "#{text.byteslice(0, MAX_DIFF_BYTES).scrub}\n… diff truncated" : text)
    end

    def summary
      {
        id: id,
        sandbox_session_id: sandbox_session.session_id,
        status: status,
        prompt: prompt,
        model: model,
        result: result,
        error_message: error_message,
        num_turns: num_turns,
        duration_ms: duration_ms,
        total_cost_usd: total_cost_usd&.to_f,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        event_count: events.size + dropped_events_count.to_i,
        started_at: started_at&.iso8601,
        finished_at: finished_at&.iso8601,
        created_at: created_at&.iso8601
      }
    end

    # The summary plus the transcript from event index +after+ onward (for
    # incremental polling) and the diff once finished.
    def details(after: 0)
      after = after.to_i.clamp(0, events.size)
      summary.merge(
        events: events.drop(after),
        events_offset: after,
        dropped_events_count: dropped_events_count.to_i,
        diff: finished? ? diff : nil
      )
    end

    private

    def truncate_strings(value)
      case value
      when String then value.length > MAX_EVENT_STRING ? "#{value[0, MAX_EVENT_STRING]}… (truncated)" : value
      when Hash then value.to_h { |key, item| [ key, truncate_strings(item) ] }
      when Array then value.map { |item| truncate_strings(item) }
      else value
      end
    end
  end
end
