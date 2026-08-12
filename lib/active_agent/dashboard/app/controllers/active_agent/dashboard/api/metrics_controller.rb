# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      # Read API for telemetry metrics, backing the dashboard Metrics view.
      #
      # Exposes the same aggregates as the gem dashboard's metrics page
      # (ActiveAgent::Dashboard::TracesController#metrics / #calculate_metrics /
      # #agent_statistics): trace counts, token totals, average duration, error
      # rate, active agents and per-agent statistics — account-scoped, plus
      # previous-period deltas for trend indicators.
      class MetricsController < BaseController
        before_action :require_owner!

        DEFAULT_WINDOW_HOURS = 24
        MAX_WINDOW_HOURS = 24 * 30

        # How to rank the per-agent table. Cost is applied after the grouped
        # query because pricing happens in Ruby (rates vary per model), so all
        # four are ordered in one place rather than half in SQL.
        AGENT_SORTS = {
          "popular" => "Most requests",
          "longest" => "Longest average",
          "cost" => "Highest cost",
          "tokens" => "Most tokens",
          "errors" => "Most errors"
        }.freeze
        DEFAULT_AGENT_SORT = "popular"

        # GET /api/metrics
        def show
          hours = params.fetch(:hours, DEFAULT_WINDOW_HOURS).to_i.clamp(1, MAX_WINDOW_HOURS)
          now = Time.current

          current = traces_scope.for_date_range(hours.hours.ago(now), now)
          previous = traces_scope.for_date_range((hours * 2).hours.ago(now), hours.hours.ago(now))

          costs = cost_statistics(current)
          priced = agent_statistics(current).map { |row| row.merge(cost: costs[:by_agent][row[:name]] || 0.0) }

          render json: {
            summary: summary_for(current, previous).merge(total_cost: costs[:total]),
            hourly_requests: hourly_requests(current, hours, now),
            by_agent: sort_agents(priced, params[:sort]),
            window_hours: hours,
            sorts: AGENT_SORTS,
            sort: agent_sort(params[:sort])
          }
        end

        private

        def agent_sort(requested)
          AGENT_SORTS.key?(requested.to_s) ? requested.to_s : DEFAULT_AGENT_SORT
        end

        # Descending on the chosen dimension; request count breaks ties so the
        # table keeps a stable, meaningful secondary order.
        def sort_agents(rows, requested)
          key = case agent_sort(requested)
          when "longest" then :avg_duration_ms
          when "cost" then :cost
          when "tokens" then :tokens
          when "errors" then :errors
          else :requests
          end

          rows.sort_by { |row| [ -row[key].to_f, -row[:requests].to_i ] }
        end

        def traces_scope
          ActiveAgent::Dashboard.trace_model.for_account(current_account)
        end

        # Same definitions as the gem dashboard's calculate_metrics, with
        # previous-period percentage changes layered on top.
        def summary_for(current, previous)
          total = current.count
          previous_total = previous.count

          input_tokens = current.sum(:total_input_tokens)
          output_tokens = current.sum(:total_output_tokens)
          thinking_tokens = current.sum(:total_thinking_tokens)

          avg_latency = current.average(:total_duration_ms)&.round(0)
          previous_avg_latency = previous.average(:total_duration_ms)&.round(0)

          error_rate = total.positive? ? (current.with_errors.count.to_f / total * 100).round(2) : 0.0

          {
            total_requests: total,
            requests_change: percent_change(previous_total, total),
            avg_latency_ms: avg_latency || 0,
            latency_change: percent_change(previous_avg_latency, avg_latency),
            error_rate: error_rate,
            errors: current.with_errors.count,
            unique_agents: current.distinct.count(:agent_class),
            tokens_used: input_tokens + output_tokens + thinking_tokens,
            tokens_input: input_tokens,
            tokens_output: output_tokens,
            tokens_thinking: thinking_tokens
          }
        end

        def hourly_requests(scope, hours, now)
          traces = ActiveAgent::Dashboard.trace_model
          bucket_sql = Arel.sql(traces.hour_bucket_sql)
          to_epoch = ->(hash) { hash.transform_keys { |key| traces.hour_bucket_epoch(key) } }

          counts = to_epoch.call(scope.group(bucket_sql).count)
          latencies = to_epoch.call(scope.group(bucket_sql).average(:total_duration_ms))

          start_hour = (now - (hours - 1).hours).beginning_of_hour
          (0...hours).map do |offset|
            bucket = start_hour + offset.hours
            {
              hour: bucket.strftime("%H:00"),
              timestamp: bucket.iso8601,
              count: counts[bucket.to_i] || 0,
              avg_latency_ms: latencies[bucket.to_i]&.round(0) || 0,
              active: offset == hours - 1
            }
          end
        end

        # Mirrors the gem dashboard's agent_statistics grouped query.
        def agent_statistics(scope)
          scope
            .where.not(agent_class: nil)
            .group(:agent_class)
            .select(
              "agent_class",
              "COUNT(*) AS trace_count",
              "SUM(total_input_tokens + total_output_tokens + total_thinking_tokens) AS token_sum",
              "AVG(total_duration_ms) AS avg_duration",
              "SUM(CASE WHEN status = 'ERROR' THEN 1 ELSE 0 END) AS error_count"
            )
            .order(Arel.sql("trace_count DESC"))
            .map do |row|
              {
                name: row.agent_class,
                requests: row.trace_count,
                tokens: row.token_sum.to_i,
                avg_duration_ms: row.avg_duration&.round(0) || 0,
                errors: row.error_count.to_i
              }
            end
        end

        # Estimated spend for the window, total and per agent class. The model
        # lives inside the spans JSON (first llm span).
        def cost_statistics(scope)
          rows = ActiveAgent::Dashboard.trace_model.pluck_with_llm_model(
            scope, :agent_class, :total_input_tokens, :total_output_tokens
          )

          by_agent = Hash.new(0.0)
          total = 0.0

          rows.each do |model, agent_class, input_tokens, output_tokens|
            cost = ModelPricing.estimate(model: model, input_tokens: input_tokens, output_tokens: output_tokens)
            next unless cost

            total += cost
            by_agent[agent_class] += cost if agent_class
          end

          { total: total.round(4), by_agent: by_agent.transform_values { |v| v.round(4) } }
        end

        def percent_change(previous, current)
          return nil if previous.nil? || current.nil? || previous.to_f.zero?

          (((current.to_f - previous.to_f) / previous.to_f) * 100).round(1)
        end
      end
    end
  end
end
