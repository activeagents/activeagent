# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Main dashboard controller showing overview metrics and recent activity.
    #
    class DashboardController < ApplicationController
      def index
        @agents = fetch_agents.limit(10)
        @recent_runs = fetch_recent_runs.limit(10)
        @recent_traces = fetch_recent_traces.limit(10)
        @metrics = calculate_metrics

        if ActiveAgent::Dashboard.use_inertia && defined?(InertiaRails)
          render inertia: "Dashboard", props: {
            agents: serialize_agents(@agents),
            recentRuns: serialize_runs(@recent_runs),
            recentTraces: serialize_traces(@recent_traces),
            metrics: @metrics,
            user: current_user_props,
            account: current_account_props
          }
        else
          render :index
        end
      end

      private

      def fetch_agents
        agents = Agent.order(updated_at: :desc)
        agents = agents.for_owner(current_owner) if current_owner
        agents
      end

      def fetch_recent_runs
        runs = AgentRun.includes(:agent).recent
        if current_owner && ActiveAgent::Dashboard.multi_tenant?
          runs = runs.joins(:agent).where(agents: { account_id: current_owner.id })
        end
        runs
      end

      def fetch_recent_traces
        traces = ActiveAgent::Dashboard.trace_model.recent
        traces = traces.for_account(current_owner) if current_owner && ActiveAgent::Dashboard.multi_tenant?
        traces
      end

      def calculate_metrics
        traces_24h = ActiveAgent::Dashboard.trace_model.where("created_at > ?", 24.hours.ago)
        runs_24h = AgentRun.where("created_at > ?", 24.hours.ago)

        if current_owner && ActiveAgent::Dashboard.multi_tenant?
          traces_24h = traces_24h.for_account(current_owner)
          runs_24h = runs_24h.joins(:agent).where(agents: { account_id: current_owner.id })
        end

        {
          total_agents: fetch_agents.count,
          active_agents: fetch_agents.active_agents.count,
          total_runs_24h: runs_24h.count,
          successful_runs_24h: runs_24h.successful.count,
          failed_runs_24h: runs_24h.failed_runs.count,
          total_traces_24h: traces_24h.count,
          total_tokens_24h: traces_24h.sum(:total_input_tokens).to_i + traces_24h.sum(:total_output_tokens).to_i,
          avg_duration_ms: runs_24h.where.not(duration_ms: nil).average(:duration_ms)&.round || 0
        }
      end

      def serialize_agents(agents)
        agents.map do |agent|
          {
            id: agent.id,
            name: agent.name,
            slug: agent.slug,
            description: agent.description,
            provider: agent.provider,
            model: agent.model,
            status: agent.status,
            presetType: agent.preset_type,
            versionCount: agent.version_count,
            updatedAt: agent.updated_at.iso8601
          }
        end
      end

      def serialize_runs(runs)
        runs.map(&:summary)
      end

      def serialize_traces(traces)
        traces.map do |trace|
          {
            id: trace.id,
            traceId: trace.trace_id,
            displayName: trace.display_name,
            status: trace.status,
            duration: trace.formatted_duration,
            tokens: trace.formatted_tokens,
            timestamp: trace.timestamp&.iso8601
          }
        end
      end

      def current_user_props
        return nil unless current_user

        {
          id: current_user.id,
          name: current_user.try(:display_name) || current_user.try(:name) || current_user.try(:email),
          email: current_user.try(:email)
        }
      end

      def current_account_props
        return nil unless current_owner && ActiveAgent::Dashboard.multi_tenant?

        {
          id: current_owner.id,
          name: current_owner.try(:name)
        }
      end
    end
  end
end
