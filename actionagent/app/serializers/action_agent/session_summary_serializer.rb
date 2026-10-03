# frozen_string_literal: true

module ActionAgent
  # Serializes one page of SessionIndex rows for the Sessions list. What each
  # row needs from other tables is read once for the page, never per row.
  #
  # Every row has `kind` and `id` (which address its timeline), `source`,
  # `title`, `preview`, `agent`, `outcome` ("failed", "passed" or nil),
  # `status`, `started_at` and `last_activity_at`, plus what its kind adds.
  class SessionSummarySerializer
    OUTCOMES = { "passed" => "passed", "failed" => "failed", "errored" => "failed" }.freeze

    # +rows+ are `{ kind:, record:, time: }` hashes in display order.
    # +failed_context_ids+ are the conversations among them with a failed run.
    def initialize(rows, recordings:, failed_context_ids: [])
      @rows = rows
      @recordings = recordings
      @failed_context_ids = failed_context_ids.to_set
    end

    # @return [Array<Hash>]
    def as_json(*)
      preload
      @rows.map do |row|
        case row[:kind]
        when "context" then context_row(row[:record], row[:time])
        when "scenario_result" then scenario_result_row(row[:record], row[:time])
        else recording_row(row[:record], row[:time])
        end
      end
    end

    private

    def records(kind)
      @rows.select { |row| row[:kind] == kind }.map { |row| row[:record] }
    end

    def preload
      contexts = records("context")
      preloader(contexts, :contextable)
      preloader(records("scenario_result"), [ :scenario, :agent_run, { evaluation_run: { evaluation: :agent } } ])
      preloader(records("recording"), agent_run: :agent)

      ids = contexts.map(&:id)
      @message_counts = ids.empty? ? {} : AgentMessage.where(agent_context_id: ids).group(:agent_context_id).count
      @recording_counts = ids.empty? ? {} : @recordings.where(agent_context_id: ids).group(:agent_context_id).count
      @first_inputs = first_user_messages(ids)
    end

    def preloader(records, associations)
      ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call if records.any?
    end

    # What each conversation was first asked. Messages are only appended, so
    # the smallest id is the first.
    def first_user_messages(ids)
      return {} if ids.empty?

      first_ids = AgentMessage.where(agent_context_id: ids, role: "user").where.not(content: [ nil, "" ])
        .group(:agent_context_id).minimum(:id)
      AgentMessage.where(id: first_ids.values).pluck(:agent_context_id, :content).to_h
    end

    def context_row(context, time)
      agent = context.contextable.is_a?(Agent) ? context.contextable : nil
      common("context", context, time).merge(
        title: "#{context.agent_name}##{context.action_name}",
        preview: InteractionPreview.line(@first_inputs[context.id]),
        agent: agent_json(agent),
        outcome: @failed_context_ids.include?(context.id) ? "failed" : nil,
        status: nil,
        message_count: @message_counts[context.id] || 0,
        recording_count: @recording_counts[context.id] || 0,
        started_at: timestamp(context.created_at)
      )
    end

    def scenario_result_row(result, time)
      scenario = result.evaluated_scenario
      evaluation = result.evaluation_run.evaluation
      common("scenario_result", result, time).merge(
        title: scenario["key"].presence || "Scenario #{result.evaluation_scenario_id}",
        preview: InteractionPreview.line(scenario["prompt"]),
        agent: agent_json(evaluation.agent),
        outcome: OUTCOMES[result.status],
        status: result.status,
        model: result.model,
        evaluation: { id: evaluation.id, name: evaluation.name, run_id: result.evaluation_run_id },
        agent_run_id: result.agent_run_id,
        started_at: timestamp(result.agent_run&.started_at || result.created_at)
      )
    end

    def recording_row(recording, time)
      run = recording.agent_run
      common("recording", recording, time).merge(
        title: recording.name.presence || "Recording #{recording.id}",
        preview: nil,
        agent: agent_json(run&.agent),
        outcome: recording.failed? || run&.failed? ? "failed" : nil,
        status: recording.status,
        recording_source: recording.source,
        event_count: recording.event_count,
        action_count: recording.action_count,
        agent_run_id: recording.agent_run_id,
        started_at: timestamp(recording.created_at)
      )
    end

    def common(kind, record, time)
      { kind: kind, id: record.id, source: SessionIndex::KINDS.fetch(kind), last_activity_at: timestamp(time) }
    end

    def agent_json(agent)
      agent && { id: agent.id, name: agent.name, slug: agent.slug }
    end

    def timestamp(time)
      time&.utc&.iso8601(3)
    end
  end
end
