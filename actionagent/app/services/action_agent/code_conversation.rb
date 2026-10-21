# frozen_string_literal: true

module ActionAgent
  # Used to carry on a Claude Code or Codex conversation: a chain of
  # CodeSessions, one per turn, the first being the root (see CodeSession).
  #
  # A turn runs only after the one before it settled, one at a time per
  # checkout. A message sent while a turn runs is queued in the conversation
  # (.post!) and started once that turn settles (.advance!, called by
  # CodeSessionJob). A turn resumes the CLI session the first turn started, so
  # it sees everything said before. That session lives in the CLI's own
  # configuration for the credential the conversation started with, so a
  # conversation keeps that credential: a turn on another is refused.
  module CodeConversation
    # A conversation's length, and how many messages may wait behind its
    # running turn.
    MAX_TURNS = 50
    MAX_QUEUED_TURNS = 3
    MAX_NOTE_CHARACTERS = 2_000

    class Refused < StandardError; end

    module_function

    # Adds a turn to +root+'s conversation: queued, and started at once when
    # nothing else runs in its checkout. The caller has checked the checkout
    # can take a session (CodeSessionsController#refusal_for) and charged the
    # execution.
    #
    # @param root [CodeSession] the conversation's first turn
    # @param prompt [String] the person's message, exactly as typed
    # @param user_id [Integer, nil] who sent it, billed for it
    # @param credential_mode [String, nil] what the turn would run on now
    # @param handoff [Hash, nil] { "taken_at", "released_at", "page_url", "by" }:
    #   the sender's own account of driving the browser since the last turn
    # @param model [String, nil]
    # @return [CodeSession] the new turn
    # @raise [Refused]
    def post!(root, prompt:, user_id:, credential_mode: nil, handoff: nil, model: nil)
      raise Refused, "Continue the conversation from its first turn" unless root.root?

      root.sandbox_session.with_lock do
        turns = root.turns
        raise Refused, "This conversation has reached its #{MAX_TURNS} turns: start a new one" if turns.size >= MAX_TURNS
        raise Refused, "#{MAX_QUEUED_TURNS} messages are already waiting in this conversation" if turns.count(&:queued?) >= MAX_QUEUED_TURNS
        if credential_mode && root.credential_mode && credential_mode != root.credential_mode
          raise Refused, "This conversation ran on another Claude Code credential (#{root.credential_mode}): start a new conversation"
        end
        if (other = busy_elsewhere(root))
          raise Refused, "Another #{other.runner == 'codex' ? 'Codex' : 'Claude Code'} session is #{other.status} in this sandbox"
        end
        raise Refused, "The first turn never started a session to continue: start a new conversation" if resume_id(root).nil?

        turn = CodeSession.create!(
          sandbox_session: root.sandbox_session,
          conversation_root: root,
          turn_index: turns.last.turn_index + 1,
          prompt: CodeSession.strip_note_tags(prompt),
          context_note: note_for(handoff),
          model: model.presence || root.model,
          runner: root.runner,
          origin: root.origin,
          credential_mode: root.credential_mode,
          resume_session_id: resume_id(root),
          user_id: user_id,
          account_id: root.account_id
        )
      end.tap { advance!(root) }
    end

    # Starts the oldest queued turn of +root+'s conversation, when no turn of
    # it runs. Called by CodeSessionJob once a turn settled, and by .post!.
    #
    # @return [CodeSession, nil] the turn started
    def advance!(root)
      root = root.root
      turn = root.sandbox_session.with_lock do
        turns = root.turns
        next nil if turns.any?(&:running?)

        # The root starts by itself (CodeSessionsController#create); a
        # follow-up waits for it. The oldest queued follow-up goes next.
        # Enqueuing one twice does no harm: CodeSessionJob claims a turn
        # atomically, and a second job finds it no longer queued.
        next nil if root.queued?

        turns.find { |candidate| candidate.queued? && !candidate.root? }
      end
      CodeSessionJob.perform_later(turn.id) if turn
      turn
    end

    # The CLI session +root+'s conversation resumes: the id the first turn
    # started with, or, for a Codex conversation, the thread its first turn
    # reported.
    def resume_id(root)
      root.runner == "codex" ? root.runner_session_id.presence : root.resume_session_id.presence
    end

    # A queued or running session in +root+'s checkout that is not a turn of
    # its conversation.
    def busy_elsewhere(root)
      root.sandbox_session.code_sessions.where(status: [ :queued, :running ])
        .where.not(id: root.id).where("conversation_root_id IS NULL OR conversation_root_id <> ?", root.id).first
    end

    # What the dashboard tells Claude ahead of the message, from the sender's
    # account of driving the browser, or nil.
    def note_for(handoff)
      return nil unless handoff.respond_to?(:to_h)

      handoff = handoff.to_h.transform_keys(&:to_s)
      by = handoff["by"].to_s.gsub(/[[:cntrl:]]/, " ").strip.presence || "The person"
      taken = timestamp(handoff["taken_at"])
      released = timestamp(handoff["released_at"])
      return nil unless taken || released

      page = handoff["page_url"].to_s[%r{\Ahttps?://[^\s<>"]{1,500}\z}]
      parts = []
      parts << "#{by} took control of the browser at #{taken}" if taken
      parts << "handed it back at #{released}" if released
      text = "#{parts.join(' and ')}."
      text += " The page on screen was #{page}." if page
      "#{text} The page may have changed: take a snapshot before acting.".truncate(MAX_NOTE_CHARACTERS)
    end

    def timestamp(value)
      Time.iso8601(value.to_s).utc.strftime("%H:%M:%S UTC")
    rescue ArgumentError
      nil
    end
  end
end
