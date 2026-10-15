# frozen_string_literal: true

module ActionAgent
  # A Claude Code or Codex conversation (CodeConversation) in the shape the
  # Interactions view lists: one row per conversation, keyed "code-<root id>"
  # beside contexts ("<id>") and reported traces ("trace-<id>"), and, in
  # detail, its turns with their transcripts.
  #
  # Each turn is one run of the CLI, so it carries what a trace would: its
  # tokens, cost and duration, from the CLI's result event.
  class CodeConversationSerializer
    LABELS = { "claude_code" => "Claude Code", "codex" => "Codex" }.freeze

    def self.summary(root, turns = root.turns)
      new(root, turns).summary
    end

    def self.detail(root, turns = root.turns, after: {})
      new(root, turns).detail(after: after)
    end

    def initialize(root, turns)
      @root = root
      @turns = turns
      @sandbox = root.sandbox_session
    end

    def summary
      last = @turns.last
      project = @sandbox.try(:project)
      {
        id: "code-#{@root.id}",
        source: "code_session",
        runner: @root.runner,
        origin: @root.origin,
        agent_name: LABELS.fetch(@root.runner, @root.runner),
        action_name: nil,
        display_name: [ LABELS.fetch(@root.runner, @root.runner), @sandbox.try(:repository) ].compact.join(" · "),
        agent: nil,
        model: @turns.filter_map(&:model).last,
        status: active&.status || last.status,
        active: !active.nil?,
        tokens: {
          input: @turns.sum { |turn| turn.input_tokens.to_i },
          output: @turns.sum { |turn| turn.output_tokens.to_i },
          total: @turns.sum { |turn| turn.input_tokens.to_i + turn.output_tokens.to_i }
        },
        total_cost_usd: @turns.sum { |turn| turn.total_cost_usd.to_f }.round(6),
        duration_ms: @turns.sum { |turn| turn.duration_ms.to_i },
        message_count: @turns.size,
        turn_count: @turns.size,
        preview: {
          input: InteractionPreview.line(@root.prompt),
          output: InteractionPreview.line(@turns.reverse.find { |turn| turn.result.present? }&.result)
        },
        sandbox_session_id: @sandbox.session_id,
        sandbox_status: @sandbox.status,
        project: project ? { id: project.id, name: project.name } : nil,
        credential_mode: @root.credential_mode,
        created_at: @root.created_at.iso8601,
        last_activity_at: (@turns.filter_map { |turn| turn.finished_at || turn.started_at }.max || last.created_at).iso8601
      }
    end

    # The summary plus every turn: its summary, and its transcript from
    # +after+[turn id] onward, so a client polling the running turn asks only
    # for what it has not seen. A finished turn's diff comes from the session
    # endpoint, on demand: it is the whole checkout's.
    def detail(after: {})
      summary.merge(
        turns: @turns.map do |turn|
          from = after[turn.id.to_s].to_i.clamp(0, turn.events.size)
          turn.summary.merge(events: turn.events.drop(from), events_offset: from,
            dropped_events_count: turn.dropped_events_count.to_i)
        end,
        browser: @sandbox.respond_to?(:browser_summary) ? @sandbox.browser_summary : nil
      )
    end

    private

    def active
      @turns.find { |turn| turn.running? } || @turns.find { |turn| turn.queued? }
    end
  end
end
