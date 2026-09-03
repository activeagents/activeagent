# frozen_string_literal: true

module ActionAgent
  module Api
    class AnalyticsController < BaseController
      # GET /api/analytics
      def index
        days = (params[:days] || 30).to_i
        start_date = days.days.ago.beginning_of_day

        # Table names are interpolated rather than written literally: the
        # engine's tables carry a configurable prefix.
        runs_table = AgentRun.table_name
        agents_table = ActionAgent::Agent.table_name

        agents = owner_agents
        runs = AgentRun.joins(:agent).where(agent: agents).where("#{runs_table}.created_at >= ?", start_date)

        # Overall stats
        total_agents = agents.count
        active_agents = agents.where(status: :active).count
        total_runs = runs.count
        completed_runs = runs.where(status: :complete).count
        failed_runs = runs.where(status: :failed).count

        # Token usage
        total_tokens = runs.sum(:total_tokens)
        total_input_tokens = runs.sum(:input_tokens)
        total_output_tokens = runs.sum(:output_tokens)

        # Average metrics
        avg_duration = runs.where.not(duration_ms: nil).average(:duration_ms)&.round || 0
        avg_tokens_per_run = total_runs > 0 ? (total_tokens.to_f / total_runs).round : 0

        # Runs over time. Zero-filled across the window: grouping only
        # returns days that have rows, and the chart draws whatever it gets
        # as adjacent bars, so a 30-day window with runs on two far-apart
        # days rendered as two neighbouring bars.
        runs_by_day = zero_filled_days(
          start_date,
          runs.group("DATE(#{runs_table}.created_at)")
            .select("DATE(#{runs_table}.created_at) as date, COUNT(*) as count")
            .map { |r| { date: r.date.to_s, count: r.count } },
          count: 0
        )

        # Token usage over time
        tokens_by_day = zero_filled_days(
          start_date,
          runs.group("DATE(#{runs_table}.created_at)")
            .select("DATE(#{runs_table}.created_at) as date, SUM(total_tokens) as tokens")
            .map { |r| { date: r.date.to_s, tokens: r.tokens || 0 } },
          tokens: 0
        )

        # Top agents by usage
        top_agents = agents.joins(:agent_runs)
          .where("#{runs_table}.created_at >= ?", start_date)
          .group("#{agents_table}.id", "#{agents_table}.name", "#{agents_table}.slug")
          .select(
            "#{agents_table}.id, #{agents_table}.name, #{agents_table}.slug, " \
            "COUNT(#{runs_table}.id) as run_count, SUM(#{runs_table}.total_tokens) as total_tokens"
          )
          .order("run_count DESC")
          .limit(5)
          .map { |a| { id: a.id, name: a.name, slug: a.slug, run_count: a.run_count, total_tokens: a.total_tokens || 0 } }

        # Status distribution
        status_breakdown = runs.group(:status).count.transform_keys(&:to_s)

        # Provider distribution
        provider_breakdown = runs.joins(:agent)
          .group("#{agents_table}.provider")
          .count
          .transform_keys(&:to_s)

        render json: {
          period_days: days,
          summary: {
            total_agents: total_agents,
            active_agents: active_agents,
            total_runs: total_runs,
            completed_runs: completed_runs,
            failed_runs: failed_runs,
            success_rate: total_runs > 0 ? ((completed_runs.to_f / total_runs) * 100).round(1) : 0,
            avg_duration_ms: avg_duration,
            total_tokens: total_tokens,
            total_input_tokens: total_input_tokens,
            total_output_tokens: total_output_tokens,
            avg_tokens_per_run: avg_tokens_per_run
          },
          charts: {
            runs_by_day: runs_by_day,
            tokens_by_day: tokens_by_day
          },
          top_agents: top_agents,
          status_breakdown: status_breakdown,
          provider_breakdown: provider_breakdown
        }
      end

      private

      # One entry per calendar day from +start_date+ through today, in
      # order, with +defaults+ for the days the grouped +rows+ did not
      # mention. Keyed on the ISO date string so it reads the same whether
      # the adapter returns DATE() as a Date or a String.
      def zero_filled_days(start_date, rows, **defaults)
        by_date = rows.index_by { |row| row[:date] }
        (start_date.to_date..Date.current).map do |day|
          by_date[day.to_s] || defaults.merge(date: day.to_s)
        end
      end
    end
  end
end
