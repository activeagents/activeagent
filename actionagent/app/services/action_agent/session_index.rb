# frozen_string_literal: true

module ActionAgent
  # Used to list the sessions a caller can replay, newest first, a page at a
  # time.
  #
  # Kinds, and the source each one is filtered by:
  #   context          dashboard   a conversation (AgentContext) of one of the
  #                                caller's agents
  #   scenario_result  evaluation  the run that replayed an evaluation scenario
  #   recording        agent       a browser recording linked to no
  #                                conversation and to no evaluation replay
  #
  # An evaluation replay writes to its agent's conversation as well, so a
  # conversation whose every generation came from evaluation replays is left
  # out: each replay is listed once, as its scenario result.
  #
  # A conversation's runs are the runs that wrote a generation to it and the
  # runs pinned to it (input_params "context_id"). A session is placed by its
  # last activity: a conversation's updated_at, a result's or a recording's
  # created_at. Pages are read with a cursor, so a deep page costs what the
  # first one does.
  class SessionIndex
    KINDS = { "context" => "dashboard", "scenario_result" => "evaluation", "recording" => "agent" }.freeze
    SOURCES = KINDS.values.uniq.freeze
    OUTCOMES = %w[failed passed].freeze
    TIME_COLUMNS = { "context" => :updated_at, "scenario_result" => :created_at, "recording" => :created_at }.freeze
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE = 100

    # An actor that matches no session, for a "mine" filter with nobody
    # signed in.
    NO_ACTOR = Object.new.freeze

    # Raised for a cursor the index cannot read.
    class InvalidCursor < ArgumentError; end

    # What narrows the index. Every member is optional.
    #
    # @!attribute agent_id
    #   @return [Integer] one of the caller's agents
    # @!attribute actor
    #   @return [Object] the user the sessions' runs were executed on behalf of
    # @!attribute source
    #   @return [String] one of SOURCES
    # @!attribute outcome
    #   @return [String] "failed" (a failed or errored replay, a conversation
    #     with a failed run, a failed recording) or "passed" (a passed replay)
    # @!attribute from
    #   @return [Time] the earliest last activity, inclusive
    # @!attribute to
    #   @return [Time] the latest last activity, exclusive
    Filters = Struct.new(:agent_id, :actor, :source, :outcome, :from, :to, keyword_init: true)

    # One position in the index: sessions after it sort older.
    Cursor = Struct.new(:time, :kind, :id) do
      # Reads a cursor written by #to_s: `<ISO 8601 time>|<kind>|<id>`.
      def self.parse(value)
        time, kind, id = value.to_s.split("|", 3)
        raise InvalidCursor unless KINDS.key?(kind) && id.to_s.match?(/\A\d+\z/)

        new(Time.iso8601(time.to_s), kind, id.to_i)
      rescue ArgumentError
        raise InvalidCursor, "Unknown cursor"
      end

      def to_s
        "#{time.utc.iso8601(6)}|#{kind}|#{id}"
      end
    end

    # +agents+ and +recordings+ are what the caller may see
    # (Api::BaseController#owner_agents and #reachable_recordings). +before+
    # is the `next_before` of the previous page.
    def initialize(agents:, recordings:, filters: Filters.new, per_page: DEFAULT_PER_PAGE, before: nil)
      @all_agents = agents
      @agents = filters.agent_id ? agents.where(id: filters.agent_id) : agents
      @recordings = recordings
      @filters = filters
      @per_page = per_page.to_i.clamp(1, MAX_PER_PAGE)
      @before = before.present? ? Cursor.parse(before) : nil
      @relations = {}
    end

    # The page as the JSON API returns it: `sessions`, `has_more`,
    # `next_before` (the cursor for the next page, nil on the last) and
    # `total` (every session the filters match).
    # @return [Hash]
    def as_json(*)
      rows = kinds.flat_map { |kind| page_rows(kind) }.sort_by { |row| sort_key(row) }
      page = rows.first(@per_page)
      more = rows.size > @per_page

      {
        sessions: SessionSummarySerializer.new(page, recordings: @recordings,
          failed_context_ids: failed_context_ids(page)).as_json,
        has_more: more,
        next_before: more ? Cursor.new(page.last[:time], page.last[:kind], page.last[:record].id).to_s : nil,
        total: kinds.sum { |kind| relation(kind).count }
      }
    end

    private

    def kinds
      KINDS.keys.select { |kind| @filters.source.nil? || KINDS[kind] == @filters.source }
    end

    # Newest first; at the same time, in KINDS order, then the newest id.
    def sort_key(row)
      [ -row[:time].to_r, KINDS.keys.index(row[:kind]), -row[:record].id ]
    end

    # The first per_page + 1 sessions of +kind+ after the cursor: enough to
    # fill the page and to tell whether another follows.
    def page_rows(kind)
      column = TIME_COLUMNS.fetch(kind)
      scope = relation(kind)
      table = scope.klass.arel_table
      after_cursor(scope, kind, table, column)
        .order(table[column].desc, table[:id].desc)
        .limit(@per_page + 1)
        .map { |record| { kind: kind, record: record, time: record.public_send(column) } }
    end

    def after_cursor(scope, kind, table, column)
      return scope unless @before

      time = table[column]
      condition =
        case KINDS.keys.index(kind) <=> KINDS.keys.index(@before.kind)
        when 1 then time.lteq(@before.time)
        when 0 then time.lt(@before.time).or(time.eq(@before.time).and(table[:id].lt(@before.id)))
        else time.lt(@before.time)
        end
      scope.where(condition)
    end

    def relation(kind)
      @relations[kind] ||= within_dates(
        case kind
        when "context" then contexts
        when "scenario_result" then scenario_results
        else recordings
        end,
        TIME_COLUMNS.fetch(kind)
      )
    end

    def within_dates(scope, column)
      table = scope.klass.arel_table
      scope = scope.where(table[column].gteq(@filters.from)) if @filters.from
      scope = scope.where(table[column].lt(@filters.to)) if @filters.to
      scope
    end

    # --- conversations --------------------------------------------------------

    def contexts
      base = AgentContext.for_agents(@agents)
      generations = AgentGeneration.where(agent_context_id: base.select(:id))
      dashboard_generations = generations.where(trace_id: nil).or(generations.where.not(trace_id: replay_traces))
      scope = base.where(id: dashboard_generations.select(:agent_context_id))
        .or(base.where.not(id: generations.select(:agent_context_id)))

      scope = with_runs(scope, AgentRun.where(agent: @all_agents).on_behalf_of(@filters.actor)) if @filters.actor
      case @filters.outcome
      when "failed" then with_runs(scope, failed_runs)
      when "passed" then scope.none
      else scope
      end
    end

    # The conversations in +scope+ that +runs+ wrote a generation to or were
    # pinned to.
    def with_runs(scope, runs)
      by_generation = AgentGeneration.where(trace_id: runs.select(:trace_id)).select(:agent_context_id)
      scope.where(id: by_generation).or(scope.where(id: pinned_context_ids(runs)))
    end

    def pinned_context_ids(runs)
      sql = AgentRun.input_param_sql("context_id")
      runs.where("#{sql} IS NOT NULL").distinct.pluck(Arel.sql(sql))
        .filter_map { |value| Integer(value.to_s, exception: false) }
    end

    def failed_runs
      AgentRun.where(agent: @all_agents, status: :failed)
    end

    # Which conversations on +page+ had a failed run.
    def failed_context_ids(page)
      ids = page.select { |row| row[:kind] == "context" }.map { |row| row[:record].id }
      return [] if ids.empty?

      with_runs(AgentContext.where(id: ids), failed_runs).pluck(:id)
    end

    # --- evaluation replays ---------------------------------------------------

    def scenario_results
      evaluations = Evaluation.where(agent: @agents).select(:id)
      scope = EvaluationScenarioResult
        .where(evaluation_run_id: EvaluationRun.where(evaluation_id: evaluations).select(:id))
        .where.not(agent_run_id: nil)

      scope = scope.where(agent_run_id: AgentRun.on_behalf_of(@filters.actor).select(:id)) if @filters.actor
      case @filters.outcome
      when "failed" then scope.where(status: %i[failed errored])
      when "passed" then scope.where(status: :passed)
      else scope
      end
    end

    def replay_run_ids
      evaluations = Evaluation.where(agent: @all_agents).select(:id)
      EvaluationScenarioResult
        .where(evaluation_run_id: EvaluationRun.where(evaluation_id: evaluations).select(:id))
        .where.not(agent_run_id: nil)
        .select(:agent_run_id)
    end

    def replay_traces
      AgentRun.where(id: replay_run_ids).where.not(trace_id: nil).select(:trace_id)
    end

    # --- browser recordings ---------------------------------------------------

    def recordings
      base = @recordings.where(agent_context_id: nil)
      scope = base.where(agent_run_id: nil).or(base.where.not(agent_run_id: replay_run_ids))
      scope = scope.where(agent_run_id: AgentRun.where(agent: @agents).select(:id)) if @filters.agent_id
      scope = recordings_by_actor(scope) if @filters.actor

      case @filters.outcome
      when "failed" then scope.where(status: :failed).or(scope.where(agent_run_id: failed_runs.select(:id)))
      when "passed" then scope.none
      else scope
      end
    end

    # A recording's runs were executed on behalf of the actor, or it is the
    # actor's own.
    def recordings_by_actor(scope)
      by_run = scope.where(agent_run_id: AgentRun.on_behalf_of(@filters.actor).select(:id))
      return by_run unless own_recording_column?

      by_run.or(scope.where(user_id: @filters.actor.id))
    end

    def own_recording_column?
      user_class = ActionAgent.user_class.to_s
      user_class.present? && @filters.actor.class.name == user_class && SessionRecording.column_names.include?("user_id")
    end
  end
end
