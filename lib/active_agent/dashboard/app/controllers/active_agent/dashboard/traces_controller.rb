# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Controller for viewing telemetry traces.
    #
    # Provides:
    # - List view with filtering and pagination
    # - Detail view with span timeline
    # - Metrics overview
    # - Live updates via Turbo Streams
    class TracesController < ApplicationController
      def index
        @traces = fetch_traces
        @metrics = calculate_metrics

        respond_to do |format|
          format.html
          format.turbo_stream
        end
      end

      def show
        @trace = ActiveAgent::TelemetryTrace.find(params[:id])
      end

      def metrics
        @metrics = calculate_metrics
        @agent_stats = agent_statistics
        @time_series = time_series_data

        respond_to do |format|
          format.html
          format.turbo_stream
        end
      end

      private

      def fetch_traces
        traces = ActiveAgent::TelemetryTrace.recent

        traces = traces.for_agent(params[:agent]) if params[:agent].present?
        traces = traces.with_errors if params[:status] == "error"
        traces = traces.for_service(params[:service]) if params[:service].present?

        if params[:start_date].present? && params[:end_date].present?
          traces = traces.for_date_range(
            Time.parse(params[:start_date]),
            Time.parse(params[:end_date])
          )
        end

        traces.limit(params[:limit] || 50)
      end

      def calculate_metrics
        traces = ActiveAgent::TelemetryTrace.where(
          "created_at > ?", 24.hours.ago
        )

        {
          total_traces: traces.count,
          total_tokens: traces.sum(:total_input_tokens) + traces.sum(:total_output_tokens),
          avg_duration_ms: traces.average(:total_duration_ms)&.round(2) || 0,
          error_rate: calculate_error_rate(traces),
          unique_agents: traces.distinct.count(:agent_class)
        }
      end

      def calculate_error_rate(traces)
        total = traces.count
        return 0.0 if total.zero?

        errors = traces.with_errors.count
        ((errors.to_f / total) * 100).round(2)
      end

      def agent_statistics
        ActiveAgent::TelemetryTrace
          .where("created_at > ?", 24.hours.ago)
          .group(:agent_class)
          .select(
            "agent_class",
            "COUNT(*) as trace_count",
            "SUM(total_input_tokens + total_output_tokens) as total_tokens",
            "AVG(total_duration_ms) as avg_duration",
            "SUM(CASE WHEN status = 'ERROR' THEN 1 ELSE 0 END) as error_count"
          )
      end

      def time_series_data
        ActiveAgent::TelemetryTrace
          .where("created_at > ?", 1.hour.ago)
          .group_by_minute(:created_at)
          .count
      rescue NoMethodError
        # Fallback if groupdate gem not available
        {}
      end
    end
  end
end
