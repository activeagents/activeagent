# frozen_string_literal: true

module ActionAgent
  # A headless Claude Code session run inside an app_runtime sandbox's
  # checkout: the prompt, the stream-json transcript as it arrived, the
  # outcome Claude Code reported, and the diff the session left in the
  # working tree.
  #
  # A session is one turn of a conversation (CodeConversation). The first
  # turn is the conversation's root; each later one names it
  # (conversation_root_id), runs after the one before it, and resumes the same
  # CLI session (resume_session_id), so Claude Code or Codex remembers what
  # came before. Every existing session is a conversation of one turn.
  #
  # The transcript is scrubbed of the sandbox's secrets (its GitHub token and
  # Claude Code credential) before it is stored, and bounded: long strings
  # are truncated and events past MAX_EVENTS are counted rather than kept.
  class CodeSession < ApplicationRecord
    include Ownable
    owned_by :user, :account

    belongs_to :sandbox_session
    belongs_to :evaluation_run, optional: true
    belongs_to :verification_run, class_name: "EvaluationRun", optional: true
    belongs_to :previous_code_session, class_name: "CodeSession", optional: true
    belongs_to :conversation_root, class_name: "CodeSession", optional: true
    has_many :follow_up_turns, -> { order(:turn_index, :id) }, class_name: "CodeSession",
      foreign_key: :conversation_root_id, inverse_of: :conversation_root

    enum :status, { queued: 0, running: 1, succeeded: 2, failed: 3, cancelled: 4 }

    MAX_PROMPT_CHARACTERS = 20_000
    MAX_EVENTS = 1_000
    # Per string inside an event: tool results can be whole files.
    MAX_EVENT_STRING = 4_000
    MAX_DIFF_BYTES = 500_000
    RUNNERS = %w[claude_code codex].freeze
    # Where a conversation was started. Older sessions recorded none; see
    # #origin.
    ORIGINS = %w[settings boot_fix evaluation_fix chat].freeze
    # A Claude Code session id, as --session-id and --resume take it.
    SESSION_UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    # A note from the dashboard is fenced in this tag ahead of the person's
    # message, and the tag is taken out of anything the person typed.
    NOTE_TAG = "dashboard-note"

    validates :prompt, presence: true, length: { maximum: MAX_PROMPT_CHARACTERS }
    validates :runner, inclusion: { in: RUNNERS }

    validates :origin, inclusion: { in: ORIGINS }, allow_nil: true
    # A Codex conversation resumes the thread id its first turn reported.
    validates :resume_session_id, format: { with: SESSION_UUID }, allow_nil: true, if: -> { runner == "claude_code" }

    # A conversation's first Claude Code turn names the CLI session it
    # starts (--session-id), so every later turn can resume it even when the
    # first ended before reporting its own id.
    before_validation(on: :create) do
      self.resume_session_id ||= SecureRandom.uuid if root? && runner == "claude_code"
    end

    scope :recent, -> { order(created_at: :desc) }
    # The first turn of every conversation.
    scope :conversation_roots, -> { where(conversation_root_id: nil) }

    # JSON columns carry no default on MySQL or SQLite (see the migration).
    def events
      Array(super)
    end

    def finished?
      succeeded? || failed? || cancelled?
    end

    def root?
      conversation_root_id.nil?
    end

    # The conversation's first turn: this one, or the one it names.
    def root
      root? ? self : conversation_root
    end

    # Every turn of this session's conversation, in order.
    #
    # @return [Array<CodeSession>]
    def turns
      # Read afresh: turns are added under the sandbox's lock while this
      # session may hold an older list.
      [ root, *CodeSession.where(conversation_root_id: root.id).order(:turn_index, :id).to_a ]
    end

    # Where the conversation was started. Sessions from before origins were
    # recorded are told apart by what they ran for.
    def origin
      super.presence || (evaluation_run_id ? "evaluation_fix" : "settings")
    end

    # What the CLI is given on stdin: the dashboard's note, fenced, ahead of
    # the person's message. The prompt itself stays what they typed.
    def stdin_text
      return prompt if context_note.blank?

      "<#{NOTE_TAG}>\n#{context_note}\n</#{NOTE_TAG}>\n\n#{prompt}"
    end

    # +text+ without the dashboard's note tags, so a person cannot make their
    # own words read as the dashboard's.
    def self.strip_note_tags(text)
      text.to_s.gsub(%r{</?\s*#{NOTE_TAG}[^>]*>}i, "")
    end

    # Whether an outcome and a diff may still be recorded for this session.
    # finished_at is set once nothing more will be: by CodeSessionJob when it
    # settles a session it ran (whatever the backend returned, raised or
    # refused), or by the cancel of a session that never left the queue. A
    # session cancelled while running is finished at once but settled only
    # when its Claude Code has stopped, so its diff may still come, and its
    # transcript still grow, until then.
    def diff_pending?
      finished_at.nil?
    end

    # The values that must never be stored: the checkout token, the Claude
    # Code credential this session ran with, and the secrets of the project
    # the checkout was booted for. The session itself never receives those.
    def secrets
      spec = sandbox_session.checkout_spec rescue nil
      [ spec&.dig(:token), *sandbox_session.runtime_environment(runner: runner).values,
        *sandbox_session.project_scrub_values ].compact
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
        claude_session_id: runner == "claude_code" ? event["session_id"] : nil,
        runner_session_id: event["session_id"],
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
        runner: runner,
        credential_mode: credential_mode,
        evaluation_run_id: evaluation_run_id,
        evaluation_id: evaluation_run&.evaluation_id,
        fix_item: fix_item,
        conversation_id: root? ? id : conversation_root_id,
        turn_index: turn_index,
        origin: origin,
        context_note: context_note,
        verification_run_id: verification_run_id,
        verification_error: verification_error,
        result: result,
        error_message: error_message,
        num_turns: num_turns,
        duration_ms: duration_ms,
        total_cost_usd: total_cost_usd&.to_f,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        event_count: events.size + dropped_events_count.to_i,
        diff_stat: finished? ? DiffStat.call(diff) : nil,
        # What a client polls until: false once nothing about the session
        # changes any more.
        diff_pending: diff_pending?,
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
        diff: finished? ? diff : nil,
        verification: evaluation_run_id ? EvaluationFixComparison.new(self).summary : nil
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
