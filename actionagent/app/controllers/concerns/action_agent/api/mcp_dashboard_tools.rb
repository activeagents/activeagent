# frozen_string_literal: true

module ActionAgent
  module Api
    # The dashboard's own evaluation and telemetry tools, served by the MCP
    # facade (Api::MCPController) so a client's coding harness can edit an
    # agent in its own checkout, run the agent's evaluations, read the runs'
    # fix items and failing traces, and iterate. The harness brings its own
    # model; the dashboard only answers these calls.
    #
    # Each tool reads under the key's owner the way the dashboard's JSON API
    # reads under the signed-in owner: evaluations of the agents the owner
    # can reach (Api::EvaluationsController), traces of the owner's tenant
    # (Api::TraceReportsController). A record outside that scope reads as
    # nonexistent.
    #
    # Names are a noun family followed by a verb (`evaluations_list`,
    # `traces_get`). Host schema tools are always `find_`, `count_` or `get_`
    # plus a model name, and agent tools are `run_<slug>`, so no host model or
    # agent slug can produce one of these names.
    #
    # A call the client can correct (an unknown id, a sandbox it cannot use)
    # comes back as a tool result with isError. The execution switch and the
    # execution quota answer as JSON-RPC errors, as they do for `run_<slug>`.
    module MCPDashboardTools
      extend ActiveSupport::Concern

      include EvaluationRunStarting

      NAMES = %w[
        evaluations_list evaluations_get evaluations_run evaluation_runs_get evaluation_runs_compare
        traces_search traces_get
      ].freeze

      LIST_LIMIT = 20
      MAX_LIST_LIMIT = 50
      SCENARIO_LIMIT = 200
      RUN_HISTORY_LIMIT = 10
      RESULT_LIMIT = 50
      MAX_RESULT_LIMIT = 200
      TRACE_WINDOW_MINUTES = 60 * 24
      MAX_TRACE_WINDOW_MINUTES = TraceReportsController::MAX_WINDOW_MINUTES
      TRACE_LIMIT = 20
      MAX_TRACE_LIMIT = 100
      MAX_TRACE_SPANS = 100
      # Strings in a result row or a span, cut past this many characters.
      MAX_STRING = 1_000

      SELECTION_PROPERTIES = {
        scenario_ids: { type: "array", items: { type: "integer" }, description: "Replay only these scenarios, by id" },
        keys: { type: "array", items: { type: "string" }, description: "Replay only these scenarios, by key" },
        group: { type: "string", description: "Replay only this scenario group" },
        models: { type: "array", items: { type: "string" }, description: "Candidate models to compare; the agent's own model when omitted" },
        sandbox_id: {
          type: "string",
          description: "A ready checkout sandbox's session id: every replay reaches that checkout's app tools, " \
                       "without the agent being edited"
        }
      }.freeze

      DEFINITIONS = [
        {
          name: "evaluations_list",
          description: "List the evaluations of this key's agents, newest first, each with its latest run's status and " \
                       "score. Filter to one agent by slug or id.",
          inputSchema: {
            type: "object",
            properties: {
              agent: { type: "string", description: "An agent's slug or id" },
              limit: { type: "integer", description: "At most this many (default #{LIST_LIMIT}, max #{MAX_LIST_LIMIT})" }
            }
          }
        },
        {
          name: "evaluations_get",
          description: "One evaluation: its criteria, its scenarios (for a scenario suite) and its #{RUN_HISTORY_LIMIT} " \
                       "most recent runs.",
          inputSchema: {
            type: "object",
            properties: { evaluation_id: { type: "integer", description: "The evaluation's id" } },
            required: [ "evaluation_id" ]
          }
        },
        {
          name: "evaluations_run",
          description: "Start a run of an evaluation. A scenario suite replays each scenario through the agent in the " \
                       "background: the run comes back pending, so poll evaluation_runs_get with its id. A sampling " \
                       "evaluation scores recorded generations and finishes before this returns.",
          inputSchema: {
            type: "object",
            properties: { evaluation_id: { type: "integer", description: "The evaluation's id" } }.merge(SELECTION_PROPERTIES),
            required: [ "evaluation_id" ]
          }
        },
        {
          name: "evaluation_runs_get",
          description: "One evaluation run: status, scores, usage, its fix items (what to change, and where) and its " \
                       "per-scenario, per-model results, each naming its telemetry trace (for traces_get) when one " \
                       "was recorded. Defaults to the evaluation's latest run.",
          inputSchema: {
            type: "object",
            properties: {
              evaluation_id: { type: "integer", description: "The evaluation's id" },
              run_id: { type: "integer", description: "The run's id; the latest run when omitted" },
              failed_only: { type: "boolean", description: "Only results that did not pass" },
              limit: { type: "integer", description: "At most this many results (default #{RESULT_LIMIT}, max #{MAX_RESULT_LIMIT})" }
            },
            required: [ "evaluation_id" ]
          }
        },
        {
          name: "evaluation_runs_compare",
          description: "Compare two runs of one evaluation, scenario by scenario and model by model: which results " \
                       "were fixed, which regressed, which still fail. Defaults to the latest run against the one before it.",
          inputSchema: {
            type: "object",
            properties: {
              evaluation_id: { type: "integer", description: "The evaluation's id" },
              base_run_id: { type: "integer", description: "The earlier run's id" },
              head_run_id: { type: "integer", description: "The later run's id" }
            },
            required: [ "evaluation_id" ]
          }
        },
        {
          name: "traces_search",
          description: "Search telemetry traces, newest first. Returns summary rows (no spans); read one in full with " \
                       "traces_get.",
          inputSchema: {
            type: "object",
            properties: {
              agent: { type: "string", description: "An agent class name (as traces report it) or a dashboard agent's slug" },
              status: { type: "string", enum: %w[error ok], description: "Only failed traces, or only successful ones" },
              service: { type: "string", description: "The reporting service's name" },
              since_minutes: {
                type: "integer",
                description: "How far back to look (default #{TRACE_WINDOW_MINUTES}, max #{MAX_TRACE_WINDOW_MINUTES})"
              },
              min_tokens: { type: "integer", description: "Only traces that used at least this many input + output tokens" },
              min_duration_ms: { type: "integer", description: "Only traces that took at least this long" },
              limit: { type: "integer", description: "At most this many (default #{TRACE_LIMIT}, max #{MAX_TRACE_LIMIT})" }
            }
          }
        },
        {
          name: "traces_get",
          description: "One trace in full: its spans, tool calls with their arguments and results, tokens, estimated " \
                       "cost and errors. Values longer than #{MAX_STRING} characters are cut and marked.",
          inputSchema: {
            type: "object",
            properties: { trace_id: { type: "string", description: "The trace's id, its OpenTelemetry trace id, or that id's first 8 characters" } },
            required: [ "trace_id" ]
          }
        }
      ].freeze

      # Raised by a tool for a call the client can correct. Answered as a tool
      # result with isError.
      class ToolError < StandardError; end

      private

      def dashboard_tools_list
        ActionAgent.mcp_dashboard_tools? ? DEFINITIONS.map(&:dup) : []
      end

      def dashboard_tool?(name)
        ActionAgent.mcp_dashboard_tools? && NAMES.include?(name)
      end

      def dashboard_tool_call(name)
        dashboard_tool_result(dispatch_dashboard_tool(name))
      rescue ToolError, RunSandbox::Refused => e
        message = SecretScrubber.scrub(e.message, dashboard_tool_secrets)
        { content: [ { type: "text", text: message } ], structuredContent: { error: message }, isError: true }
      end

      def dispatch_dashboard_tool(name)
        case name
        when "evaluations_list" then evaluations_list_tool
        when "evaluations_get" then evaluations_get_tool
        when "evaluations_run" then evaluations_run_tool
        when "evaluation_runs_get" then evaluation_runs_get_tool
        when "evaluation_runs_compare" then evaluation_runs_compare_tool
        when "traces_search" then traces_search_tool
        when "traces_get" then traces_get_tool
        end
      end

      # The payload as JSON-compatible data with every credential the owner
      # holds masked.
      def dashboard_tool_result(payload)
        payload = SecretScrubber.scrub(payload.as_json, dashboard_tool_secrets)
        { content: [ { type: "text", text: payload.to_json } ], structuredContent: payload }
      end

      def evaluations_list_tool
        scope = dashboard_evaluations
        if (agent = tool_argument(:agent).presence)
          scope = scope.where(agent: resolve_tool_agent!(agent))
        end
        limit = integer_argument(:limit, default: LIST_LIMIT, min: 1, max: MAX_LIST_LIMIT)
        evaluations = scope.includes(:agent, :scenarios, evaluation_runs: :agent_version).recent.limit(limit).to_a
        EvaluationStanding.preload(evaluations)

        {
          evaluations: evaluations.map do |evaluation|
            summary = EvaluationSerializer.summary(evaluation)
            latest = EvaluationSerializer.recent_runs(evaluation, 1).first
            summary.slice(:id, :name, :agent, :judge_kind, :scenario_suite, :scenario_count, :scenario_groups, :created_at, :run_count,
                          :headline_run_id, :standing, :archived_at)
              .merge(latest_run: latest && EvaluationSerializer.run_summary(latest, number: summary[:run_count]))
          end
        }
      end

      def evaluations_get_tool
        evaluation = find_tool_evaluation!
        run_count = evaluation.evaluation_runs.count
        runs = evaluation.evaluation_runs.recent.limit(RUN_HISTORY_LIMIT).to_a
        scenarios = evaluation.scenarios.ordered.limit(SCENARIO_LIMIT + 1).map(&:as_json_summary)

        {
          evaluation: EvaluationSerializer.summary(evaluation),
          scenarios: PayloadBounds.bound(scenarios.first(SCENARIO_LIMIT), max_string: MAX_STRING, max_items: SCENARIO_LIMIT),
          scenarios_truncated: scenarios.size > SCENARIO_LIMIT,
          runs: runs.each_with_index.map { |run, index| EvaluationSerializer.run_summary(run, number: run_count - index) }
        }
      end

      # Checked in the order Api::EvaluationsController#run checks a request:
      # the execution switch, an executable agent, the execution quota, then
      # the sandbox. Only a scenario suite executes the agent, so a sampling
      # run passes the first three. Each replay counts one execution as it
      # runs (ScenarioEvaluationRunner), so starting the run records none.
      def evaluations_run_tool
        evaluation = find_tool_evaluation!
        if evaluation.scenario_suite?
          raise MCPController::McpError.new("Agent execution is disabled on this dashboard") unless ActionAgent.execution_enabled?
          if unexecutable_scenario_run?(evaluation)
            raise ToolError, "Observed agents are read-only — duplicate this agent to create an executable copy"
          end
          if (denial = ActionAgent.quota_denial(current_owner, :execution)).present?
            raise MCPController::McpError.new(denial.is_a?(Hash) ? denial[:message] || denial["message"] : denial)
          end
        end

        selection = evaluation_run_selection(tool_arguments)
        if (sandbox = evaluation_run_sandbox(evaluation, tool_argument(:sandbox_id).presence))
          selection[:sandbox_id] = sandbox.session_id
        end
        run = start_evaluation_run(evaluation, selection)

        {
          evaluation: { id: evaluation.id, name: evaluation.name },
          run: EvaluationSerializer.run_summary(run, number: EvaluationSerializer.run_number(evaluation, run))
            .merge(selection: run.selection, error_message: run.error_message),
          background: evaluation.scenario_suite?
        }
      end

      def evaluation_runs_get_tool
        evaluation = find_tool_evaluation!
        run = find_tool_run!(evaluation, tool_argument(:run_id), label: "run_id")
        limit = integer_argument(:limit, default: RESULT_LIMIT, min: 1, max: MAX_RESULT_LIMIT)

        results = run.scenario_results.includes(:scenario, :agent_run).joins(:scenario)
          .order(EvaluationScenario.arel_table[:position], EvaluationScenario.arel_table[:id], :model)
        results = results.where.not(status: :passed) if boolean_argument(:failed_only)
        total = results.count
        page = results.limit(limit).to_a
        recorded = recorded_trace_ids(page.filter_map { |result| result.agent_run&.trace_id })
        rows = page.map { |result| result_row(result, recorded) }

        {
          evaluation: { id: evaluation.id, name: evaluation.name, agent: evaluation.agent.slug },
          run: EvaluationSerializer.run(run, number: EvaluationSerializer.run_number(evaluation, run)),
          fix_items: PayloadBounds.bound(EvaluationSerializer.fix_items(run, links: dashboard_links(run)), max_string: MAX_STRING),
          results: rows.map { |row| PayloadBounds.bound(row, max_string: MAX_STRING, max_items: 20) },
          results_total: total,
          results_omitted: [ total - rows.size, 0 ].max
        }
      end

      def evaluation_runs_compare_tool
        evaluation = find_tool_evaluation!
        base_id = tool_argument(:base_run_id)
        head_id = tool_argument(:head_run_id)
        head = find_tool_run!(evaluation, head_id, label: "head_run_id")
        base =
          if base_id.present?
            find_tool_run!(evaluation, base_id, label: "base_run_id")
          else
            evaluation.evaluation_runs.where("created_at < ? OR (created_at = ? AND id < ?)", head.created_at, head.created_at, head.id)
              .recent.first or raise ToolError, "Run #{head.id} is the evaluation's first run; there is nothing to compare it with"
          end

        base_rows = comparison_rows(base)
        head_rows = comparison_rows(head)
        changes = (base_rows.keys | head_rows.keys).filter_map do |key|
          before = base_rows[key]
          after = head_rows[key]
          change = comparison_change(before, after)
          next if change == "unchanged_pass"

          { scenario_key: key[0], model: key[1], change: change, before: before&.status, after: after&.status,
            fault: after&.fault, result_id: after&.id }
        end

        {
          evaluation: { id: evaluation.id, name: evaluation.name },
          base_run: EvaluationSerializer.run_summary(base, number: EvaluationSerializer.run_number(evaluation, base)),
          head_run: EvaluationSerializer.run_summary(head, number: EvaluationSerializer.run_number(evaluation, head)),
          counts: changes.group_by { |change| change[:change] }.transform_values(&:size),
          changes: PayloadBounds.bound(changes, max_items: MAX_RESULT_LIMIT)
        }
      end

      def traces_search_tool
        window = integer_argument(:since_minutes, default: TRACE_WINDOW_MINUTES, min: 1, max: MAX_TRACE_WINDOW_MINUTES)
        limit = integer_argument(:limit, default: TRACE_LIMIT, min: 1, max: MAX_TRACE_LIMIT)
        model = ActionAgent.trace_model

        scope = owned_traces.for_date_range(window.minutes.ago, Time.current)
        if (agent = tool_argument(:agent).presence)
          by_slug = owner_agents.find_by(slug: agent.to_s)
          scope = by_slug ? scope.where(agent_id: by_slug.id).or(scope.for_agent(agent.to_s)) : scope.for_agent(agent.to_s)
        end
        scope = scope.for_service(tool_argument(:service).to_s) if tool_argument(:service).present?
        case tool_argument(:status).to_s.downcase
        when "error" then scope = scope.with_errors
        when "ok" then scope = scope.where.not(status: model::STATUS_ERROR)
        end
        if (min_tokens = integer_argument(:min_tokens, default: nil))
          table = model.quoted_table_name
          scope = scope.where(
            "COALESCE(#{table}.total_input_tokens, 0) + COALESCE(#{table}.total_output_tokens, 0) >= ?", min_tokens
          )
        end
        if (min_duration = integer_argument(:min_duration_ms, default: nil))
          scope = scope.where(model.arel_table[:total_duration_ms].gteq(min_duration))
        end

        traces = scope.recent.limit(limit + 1).to_a

        {
          traces: traces.first(limit).map { |trace| PayloadBounds.bound(TelemetryTraceSerializer.row(trace), max_string: MAX_STRING) },
          truncated: traces.size > limit,
          window_minutes: window
        }
      end

      # Looked up as Api::TraceReportsController#show looks a trace up: the
      # OpenTelemetry trace id, then a prefix of it, then the record id.
      def traces_get_tool
        id = tool_argument(:trace_id).to_s
        raise MCPController::McpError.new("Missing required argument: trace_id", MCPController::JSONRPC_INVALID_PARAMS) if id.blank?

        scope = owned_traces
        trace = scope.find_by(trace_id: id) ||
          scope.where("trace_id LIKE ?", "#{ActionAgent.trace_model.sanitize_sql_like(id)}%").first ||
          (id.match?(/\A\d+\z/) && scope.find_by(id: id)) or
          raise ToolError, "No trace #{id.truncate(64)} was found"

        detail = TelemetryTraceSerializer.detail(trace)
        spans = detail.delete(:spans)
        failed_spans = spans.select { |span| span[:error] }.map do |span|
          span.slice(:span_id, :name, :type).merge(message: span.dig(:attributes, "error.message"))
        end

        payload = detail.merge(
          tool_calls: trace.tool_usage,
          failed_spans: failed_spans,
          spans: spans.first(MAX_TRACE_SPANS),
          spans_total: spans.size,
          spans_omitted: [ spans.size - MAX_TRACE_SPANS, 0 ].max
        )
        PayloadBounds.bound(payload, max_string: MAX_STRING, max_items: MAX_TRACE_SPANS)
      end

      # `trace_id` names the result's telemetry trace for traces_get, and is
      # nil when telemetry recorded none for the replay.
      def result_row(result, recorded_trace_ids)
        {
          id: result.id,
          scenario_key: result.evaluated_scenario["key"],
          group: result.evaluated_scenario["group"],
          prompt: result.evaluated_scenario["prompt"],
          model: result.model,
          status: result.status,
          score: result.score,
          fault: result.fault,
          recommendation: result.recommendation,
          diagnosis: result.evaluation_diagnosis,
          output: result.output,
          tool_calls: result.tool_calls,
          error_message: result.error_message,
          duration_ms: result.duration_ms,
          input_tokens: result.input_tokens,
          output_tokens: result.output_tokens,
          cost: result.cost&.to_f,
          agent_run_id: result.agent_run_id,
          trace_id: recorded_trace_ids.include?(result.agent_run&.trace_id) ? result.agent_run.trace_id : nil
        }
      end

      # The subset of +trace_ids+ the owner's telemetry holds.
      def recorded_trace_ids(trace_ids)
        return Set.new if trace_ids.empty?

        owned_traces.where(trace_id: trace_ids).pluck(:trace_id).to_set
      end

      # The run's results keyed by [scenario key, model].
      def comparison_rows(run)
        run.scenario_results.includes(:scenario).index_by { |result| [ result.evaluated_scenario["key"], result.model ] }
      end

      # One of: removed, added_pass, added_fail, unchanged_pass, regressed,
      # fixed, still_failing.
      def comparison_change(before, after)
        return "removed" if after.nil?
        return after.passed? ? "added_pass" : "added_fail" if before.nil?
        return after.passed? ? "unchanged_pass" : "regressed" if before.passed?

        after.passed? ? "fixed" : "still_failing"
      end

      # Fix item links at the facade's absolute mount, since a client has no
      # dashboard page to resolve a relative path against.
      def dashboard_links(run)
        run.report_links(mount: "#{request.base_url}#{request.script_name}")
      end

      def dashboard_evaluations
        Evaluation.joins(:agent).where(agent: owner_agents)
      end

      def find_tool_evaluation!
        id = tool_argument(:evaluation_id)
        raise MCPController::McpError.new("Missing required argument: evaluation_id", MCPController::JSONRPC_INVALID_PARAMS) if id.blank?

        dashboard_evaluations.find_by(id: id.to_s) or raise ToolError, "No evaluation #{id.to_s.truncate(32)} was found"
      end

      # The evaluation's run +id+ names, or its latest run when +id+ is blank.
      def find_tool_run!(evaluation, id, label:)
        if id.blank?
          evaluation.evaluation_runs.recent.first or raise ToolError, "Evaluation #{evaluation.id} has not been run yet"
        else
          evaluation.evaluation_runs.find_by(id: id.to_s) or
            raise ToolError, "No run #{id.to_s.truncate(32)} of evaluation #{evaluation.id} was found (#{label})"
        end
      end

      def resolve_tool_agent!(value)
        agents = owner_agents
        agents.find_by(slug: value.to_s) || (value.to_s.match?(/\A\d+\z/) && agents.find_by(id: value.to_s)) or
          raise ToolError, "No agent #{value.to_s.truncate(64)} was found"
      end

      def tool_arguments
        @tool_arguments ||= begin
          arguments = params.dig(:params, :arguments)
          arguments.is_a?(ActionController::Parameters) ? arguments : ActionController::Parameters.new({})
        end
      end

      def tool_argument(name)
        tool_arguments[name]
      end

      # An integer argument clamped into [min, max], or +default+ when absent
      # or not a number.
      def integer_argument(name, default:, min: nil, max: nil)
        raw = tool_argument(name)
        value = raw.is_a?(Integer) || raw.to_s.match?(/\A-?\d+\z/) ? raw.to_i : default
        return value if value.nil?

        value = [ value, min ].max if min
        value = [ value, max ].min if max
        value
      end

      def boolean_argument(name)
        ActiveModel::Type::Boolean.new.cast(tool_argument(name)) == true
      end

      # Every credential the owner holds, masked out of each tool's output:
      # this key's token and the #owner_credentials. None of them belongs in
      # these payloads; this keeps one that leaked into a recorded output or a
      # trace from being handed on. A failed lookup masks only this key's
      # token rather than failing the call.
      def dashboard_tool_secrets
        @dashboard_tool_secrets ||= [ @api_key&.token, *owner_credentials ].compact
      rescue StandardError => e
        Rails.logger.warn("[ActionAgent] MCP secret lookup failed: #{e.class}: #{e.message}")
        @dashboard_tool_secrets = [ @api_key&.token ].compact
      end
    end
  end
end
