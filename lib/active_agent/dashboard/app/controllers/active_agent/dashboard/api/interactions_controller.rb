# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      # Read API for agent conversation contexts (solid_agent persistence),
      # backing the dashboard Interactions view.
      #
      # A context is one agent's interaction stream (AgentContext +
      # AgentMessages + AgentGenerations, recorded by SolidAgent::HasContext
      # during execution), scoped to the current user's agents.
      class InteractionsController < BaseController
        before_action :require_owner!

        DEFAULT_LIMIT = 50
        MAX_WINDOW_MINUTES = 60 * 24 * 90

        # GET /api/interactions
        def index
          limit = params.fetch(:limit, DEFAULT_LIMIT).to_i.clamp(1, 200)

          contexts = interactions_scope
            .includes(:contextable)
            .then { |scope| window_minutes ? scope.where(updated_at: window_minutes.minutes.ago..) : scope }
            .recent
            .limit(limit)

          message_counts = AgentMessage.where(agent_context_id: contexts.map(&:id)).group(:agent_context_id).count
          generation_counts = AgentGeneration.where(agent_context_id: contexts.map(&:id)).group(:agent_context_id).count
          # Latest model per context, so list rows can gauge context-window
          # pressure without loading generations.
          # DISTINCT ON would do this in one pass on PostgreSQL but has no
          # portable equivalent, so take the newest generation id per context
          # (they are only ever appended) and read those rows.
          newest_ids = AgentGeneration
            .where(agent_context_id: contexts.map(&:id))
            .group(:agent_context_id)
            .maximum(:id)
          latest_models = AgentGeneration.where(id: newest_ids.values)
            .pluck(:agent_context_id, :model).to_h

          persisted = contexts.map do |context|
            serialize_context(context).merge(
              source: "platform",
              model: latest_models[context.id],
              message_count: message_counts[context.id] || 0,
              generation_count: generation_counts[context.id] || 0
            )
          end

          reported = reported_traces(limit).map { |trace| TraceInteractionSerializer.summary(trace) }

          render json: {
            interactions: (persisted + reported).sort_by { |row| row[:last_activity_at].to_s }.reverse.first(limit)
          }
        end

        # GET /api/interactions/:id
        def show
          if (trace_id = params[:id].to_s[/\Atrace-(\d+)\z/, 1])
            trace = owned_traces.find(trace_id)
            return render json: { interaction: TraceInteractionSerializer.detail(trace) }
          end

          context = interactions_scope.find(params[:id])

          render json: {
            interaction: serialize_context(context).merge(
              source: "platform",
              instructions: context.instructions,
              messages: context.messages.chronological.map { |message| serialize_message(message) },
              generations: context.generations.order(created_at: :asc).map { |generation| serialize_generation(generation) }
            )
          }
        end

        private

        # Agents executing outside the platform never write solid_agent contexts —
        # they only report traces. Every reported trace is an interaction: one run
        # of one agent. Traces without captured content still show their tool calls,
        # timings, and generation metadata, so filtering on the presence of a
        # prompt would hide most runs (locally: 9 of 11) and make the per-agent
        # counts disagree with Traces for the same window.
        def reported_traces(limit)
          scope = owned_traces.where.not(agent_class: nil)
          scope = scope.where(timestamp: window_minutes.minutes.ago..) if window_minutes
          # Honor the agent filter the persisted side already applies: without
          # this, a per-agent view listed every agent's reported traffic, and an
          # agent whose traces are all SDK-reported showed nothing of its own.
          scope = scope.merge(traces_for_agent(params[:agent_id])) if params[:agent_id].present?
          scope.order(timestamp: :desc).limit(limit)
        end

        # Traces belong to an agent by foreign key once AgentRegistrar attributes
        # them; older rows predate that, so fall back to the class name.
        def traces_for_agent(agent_id)
          agent = owner_agents.find_by(id: agent_id)
          return ActiveAgent::Dashboard.trace_model.none unless agent

          ActiveAgent::Dashboard.trace_model.where(agent_id: agent.id)
            .or(ActiveAgent::Dashboard.trace_model.where(agent_id: nil, agent_class: agent.telemetry_agent_class))
        end

        # The dashboard-wide time window, shared with Traces. Absent means "all".
        def window_minutes
          return @window_minutes if defined?(@window_minutes)

          raw = params[:minutes].presence
          @window_minutes = raw ? raw.to_i.clamp(1, MAX_WINDOW_MINUTES) : nil
        end

        def interactions_scope
          agents = owner_agents
          agents = agents.where(id: params[:agent_id]) if params[:agent_id].present?
          AgentContext.for_agents(agents)
        end

        def serialize_context(context)
          agent = context.contextable
          {
            id: context.id,
            agent_name: context.agent_name,
            action_name: context.action_name,
            display_name: "#{context.agent_name}##{context.action_name}",
            agent: agent.is_a?(Agent) ? { id: agent.id, name: agent.name, slug: agent.slug } : nil,
            tokens: {
              input: context.total_input_tokens,
              output: context.total_output_tokens,
              total: context.total_tokens
            },
            created_at: context.created_at.iso8601,
            last_activity_at: context.updated_at.iso8601
          }
        end

        def serialize_message(message)
          AgentMessageSerializer.call(message)
        end

        def serialize_generation(generation)
          {
            id: generation.id,
            model: generation.model,
            provider: generation.provider,
            finish_reason: generation.finish_reason,
            tokens: {
              input: generation.input_tokens,
              output: generation.output_tokens,
              total: generation.total_tokens,
              cached: generation.cached_tokens,
              thinking: generation.reasoning_tokens
            },
            cache_hit: generation.cache_hit?,
            thinking: generation.thinking?,
            duration_seconds: generation.duration_seconds,
            trace_id: generation.trace_id,
            created_at: generation.created_at.iso8601(3)
          }
        end
      end
    end
  end
end
