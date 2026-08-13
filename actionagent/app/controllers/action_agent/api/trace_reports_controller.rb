# frozen_string_literal: true

module ActionAgent
  module Api
    # Read API for telemetry traces, backing the dashboard's Traces view.
    #
    # Query logic mirrors the server-rendered TracesController (same scopes
    # on ActionAgent.trace_model), scoped to the caller's tenant.
    # Named apart from Api::TracesController because that one is the ingest
    # endpoint: same /api/traces path, different verb and different auth.
    class TraceReportsController < BaseController
      before_action :require_owner!

      DEFAULT_WINDOW_MINUTES = 60
      MAX_WINDOW_MINUTES = 60 * 24 * 90
      DEFAULT_LIMIT = 500

      # GET /api/traces
      def index
        window = params.fetch(:minutes, DEFAULT_WINDOW_MINUTES).to_i.clamp(1, MAX_WINDOW_MINUTES)
        window_scope = traces_scope.for_date_range(window.minutes.ago, Time.current)

        scope = window_scope
        scope = scope.for_agent(params[:agent]) if params[:agent].present?
        scope = scope.for_service(params[:service]) if params[:service].present?
        scope = scope.with_errors if params[:status] == "error"

        limit = params.fetch(:limit, DEFAULT_LIMIT).to_i.clamp(1, 1000)
        traces = scope.recent.limit(limit)

        render json: {
          traces: traces.map { |trace| TelemetryTraceSerializer.summary(trace) },
          agents: window_scope.distinct.pluck(:agent_class).compact.sort,
          # agent_class => platform Agent id, so the Traces view can link a
          # trace back to the agent it belongs to (AgentRegistrar attributes
          # SDK-reported traces to an Agent record on ingest).
          agent_ids: agent_ids_by_class(window_scope),
          window_minutes: window
        }
      end

      # GET /api/traces/:id — accepts the record id or the OTel trace_id
      # (full or 8-char short form), so generation refs can deep-link.
      def show
        trace = traces_scope.find_by(trace_id: params[:id]) ||
          traces_scope.where("trace_id LIKE ?", "#{ActionAgent.trace_model.sanitize_sql_like(params[:id].to_s)}%").first ||
          traces_scope.find(params[:id])
        render json: { trace: TelemetryTraceSerializer.detail(trace) }
      end

      private

      def traces_scope
        ActionAgent.trace_model.for_account(current_account)
      end

      # One grouped query. A class can appear under several agent records
      # (same class, different action); the most recently active one wins,
      # since that's what the operator most likely means by "this agent".
      def agent_ids_by_class(scope)
        scope
          .where.not(agent_id: nil, agent_class: nil)
          .group(:agent_class)
          .maximum(:agent_id)
      end
    end
  end
end
