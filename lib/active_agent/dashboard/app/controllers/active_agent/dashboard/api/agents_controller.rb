# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      class AgentsController < BaseController
        # Ranking for the agent cards. Every dimension except "recent" reads the
        # scorecard, which is computed in Ruby over both execution sources, so
        # the ordering is applied there rather than in the SQL scope.
        LIST_SORTS = {
          "recent" => "Recently updated",
          "popular" => "Most runs",
          "longest" => "Longest average",
          "cost" => "Highest cost",
          "tokens" => "Most tokens"
        }.freeze
        DEFAULT_LIST_SORT = "recent"

        before_action :set_agent, only: [ :show, :update, :destroy, :versions, :runs, :execute, :test, :restore, :duplicate, :export, :analytics ]
        before_action :require_execution_enabled!, only: [ :execute, :test ]
        before_action :require_owner!, only: [ :execute, :test ]
        before_action :enforce_execution_quota!, only: [ :execute, :test ]

        # GET /api/agents
        def index
          @agents = owner_agents.order(updated_at: :desc)

          # Filter by status
          @agents = @agents.where(status: params[:status]) if params[:status].present?

          # Filter by provider
          @agents = @agents.where(provider: params[:provider]) if params[:provider].present?

          # Search by name
          # LOWER(...) LIKE rather than ILIKE: the dashboard is not
          # PostgreSQL-only.
          if params[:q].present?
            @agents = @agents.where("LOWER(name) LIKE ?", "%#{params[:q].to_s.downcase}%")
          end

          scorecards = AgentScorecard.for_agents(@agents)
          cards = sort_cards(
            @agents.map { |agent| agent_json(agent).merge(stats: scorecards[agent.id]) },
            params[:sort]
          )

          render json: {
            agents: cards,
            meta: {
              total: cards.size,
              sorts: LIST_SORTS,
              sort: list_sort(params[:sort]),
              providers: Agent::PROVIDERS,
              preset_types: Agent::PRESET_TYPES,
              instruction_sets: Agent::INSTRUCTION_SETS,
              available_tools: Agent::AVAILABLE_TOOLS
            }
          }
        end

        # GET /api/agents/:id
        def show
          render json: {
            agent: agent_json(@agent, include_details: true),
            versions: @agent.agent_versions.recent.limit(10).map { |v| version_json(v) },
            recent_runs: @agent.agent_runs.recent.limit(5).map(&:summary)
          }
        end

        # POST /api/agents
        def create
          @agent = owner_agents.build(agent_params)

          if @agent.save
            render json: { agent: agent_json(@agent, include_details: true) }, status: :created
          else
            render json: { errors: @agent.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/agents/:id
        def update
          if @agent.update(agent_params)
            render json: { agent: agent_json(@agent, include_details: true) }
          else
            render json: { errors: @agent.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/agents/:id
        def destroy
          @agent.destroy
          render json: { success: true }
        end

        # GET /api/agents/:id/versions
        def versions
          @versions = @agent.agent_versions.recent

          render json: {
            versions: @versions.map { |v| version_json(v, include_diff: true) }
          }
        end

        # POST /api/agents/:id/restore
        def restore
          version = @agent.agent_versions.find(params[:version_id])
          @agent.restore_from_version!(version)

          render json: { agent: agent_json(@agent, include_details: true) }
        end

        # GET /api/agents/:id/runs
        # Every execution of this agent, whoever ran it: dashboard runs and
        # SDK-reported traces in one list, discriminated by `source`. Agents
        # observed from telemetry have no AgentRun rows at all, so a runs-only
        # list showed them as empty while their scorecard reported real traffic.
        def runs
          minutes = params[:minutes].presence&.then { |m| m.to_i.clamp(1, 60 * 24 * 90) }
          page = (params[:page] || 1).to_i
          per_page = (params[:per_page] || 20).to_i

          executions = AgentExecutions.new(
            agents: [ @agent ],
            owner: current_owner,
            window_minutes: minutes,
            source: params[:source],
            status: params[:status],
            sort: params[:sort]
          ).page(page: page, per_page: per_page)

          # One digest->version map for the page; labels each run's instructions
          # with the agent version that introduced them where one matches.
          digest_versions = @agent.instructions_digest_versions
          runs_by_id = AgentRun.where(id: executions[:rows].select { |r| r.source == "dashboard" }.map(&:id))
            .index_by(&:id)

          render json: {
            runs: executions[:rows].map { |row| serialize_execution(row, runs_by_id, digest_versions) },
            meta: {
              page: page,
              per_page: per_page,
              total: executions[:total],
              sources: AgentExecutions::SOURCES,
              sorts: AgentExecutions::SORTS
            }
          }
        end

        # POST /api/agents/:id/execute
        def execute
          run = @agent.execute(
            params[:prompt],
            action: params[:action_name],
            **params.fetch(:params, {}).to_unsafe_h.symbolize_keys
          )
          record_execution_usage

          render json: { run: run.summary }, status: :accepted
        end

        # POST /api/agents/:id/test
        def test
          run = @agent.test_execute(
            params[:prompt],
            action: params[:action_name],
            **params.fetch(:params, {}).to_unsafe_h.symbolize_keys
          )
          record_execution_usage

          render json: { run: run.summary, output: run.output }
        end

        # POST /api/agents/:id/duplicate
        def duplicate
          new_agent = @agent.dup
          new_agent.name = "#{@agent.name} (Copy)"
          new_agent.slug = nil # Will be auto-generated
          new_agent.status = :draft
          new_agent.save!

          render json: { agent: agent_json(new_agent, include_details: true) }, status: :created
        end

        # GET /api/agents/:id/export
        def export
          render json: {
            agent: agent_json(@agent, include_details: true),
            code: @agent.to_agent_class_code,
            manifest: {
              name: @agent.slug,
              version: "1.0.0",
              model: "#{@agent.provider}/#{@agent.model}",
              description: @agent.description,
              instructions: @agent.instructions,
              tools: @agent.tools,
              config: @agent.model_config
            }
          }
        end

        # GET /api/agents/:id/analytics
        def analytics
          days = (params[:days] || 30).to_i
          start_date = days.days.ago.beginning_of_day

          runs = @agent.agent_runs.where("created_at >= ?", start_date)

          # Calculate stats
          total_runs = runs.count
          completed_runs = runs.where(status: :complete).count
          failed_runs = runs.where(status: :failed).count
          avg_duration = runs.where.not(duration_ms: nil).average(:duration_ms)&.round || 0
          total_tokens = runs.sum(:total_tokens)
          avg_tokens = total_runs > 0 ? (total_tokens.to_f / total_runs).round : 0

          # Runs by day
          runs_by_day = runs.group("DATE(created_at)")
            .select("DATE(created_at) as date, COUNT(*) as count, SUM(total_tokens) as tokens")
            .order("date")
            .map { |r| { date: r.date.to_s, count: r.count, tokens: r.tokens || 0 } }

          # Status breakdown
          status_breakdown = runs.group(:status).count.transform_keys(&:to_s)

          # Recent errors
          recent_errors = runs.failed_runs.recent.limit(5).map do |run|
            {
              id: run.id,
              error: run.error_message&.truncate(200),
              created_at: run.created_at
            }
          end

          render json: {
            period_days: days,
            summary: {
              total_runs: total_runs,
              completed_runs: completed_runs,
              failed_runs: failed_runs,
              success_rate: total_runs > 0 ? ((completed_runs.to_f / total_runs) * 100).round(1) : 0,
              avg_duration_ms: avg_duration,
              total_tokens: total_tokens,
              avg_tokens_per_run: avg_tokens
            },
            runs_by_day: runs_by_day,
            status_breakdown: status_breakdown,
            recent_errors: recent_errors
          }
        end

        # GET /api/agents/presets
        def presets
          presets = Agent::PRESET_TYPES.map do |preset|
            {
              id: preset,
              name: preset.titleize,
              appearance: default_appearance_for(preset),
              suggested_tools: suggested_tools_for(preset),
              suggested_instructions: suggested_instructions_for(preset)
            }
          end

          render json: { presets: presets }
        end

        private

        def list_sort(requested)
          LIST_SORTS.key?(requested.to_s) ? requested.to_s : DEFAULT_LIST_SORT
        end

        # Descending on the chosen dimension. Agents with nothing to rank (no
        # runs, no priced spend) sort last instead of interleaving as zeroes,
        # and run count breaks ties.
        def sort_cards(cards, requested)
          sort = list_sort(requested)
          return cards if sort == "recent"

          key = { "popular" => :runs, "longest" => :avg_duration_ms, "cost" => :cost, "tokens" => :tokens }[sort]

          cards.sort_by do |card|
            value = card[:stats]&.dig(key)
            [ value.nil? ? 1 : 0, -value.to_f, -card[:stats].to_h[:runs].to_i ]
          end
        end

        # Dashboard runs keep their full summary (logs, previews, instructions
        # version); reported executions carry only what a trace knows. `source`
        # tells the UI which it is holding.
        def serialize_execution(row, runs_by_id, digest_versions)
          run = runs_by_id[row.id] if row.source == "dashboard"

          if run
            run.summary.merge(
              source: "dashboard",
              # Priced here rather than on AgentRun so both sources use one
              # estimator, and so a run and its trace never quote different costs.
              cost: row.cost,
              instructions_version: digest_versions[run.instructions_digest]
            )
          else
            row.as_json.merge(id: row.to_param, record_id: row.id)
          end
        end

        # Same contract as Api::SandboxesController#run: 402 + usage stats so the
        # frontend can show the upgrade prompt.
        def set_agent
          @agent = owner_agents.find(params[:id])
        end

        def agent_params
          params.require(:agent).permit(
            :name, :description, :provider, :model, :instructions,
            :preset_type, :agent_class_name, :status,
            appearance: {},
            action_prompts: [ :name, :prompt, :expose_as_tool ],
            instruction_sets: [],
            tools: [],
            mcp_servers: [],
            model_config: {},
            response_format: {}
          )
        end

        def agent_json(agent, include_details: false)
          json = {
            id: agent.id,
            name: agent.name,
            slug: agent.slug,
            description: agent.description,
            provider: agent.provider,
            model: agent.model,
            status: agent.status,
            preset_type: agent.preset_type,
            appearance: agent.appearance,
            version_count: agent.version_count,
            created_at: agent.created_at,
            updated_at: agent.updated_at
          }

          if include_details
            json.merge!(
              instructions: agent.instructions,
              action_prompts: agent.action_prompts,
              instruction_sets: agent.instruction_sets,
              tools: agent.tools,
              mcp_servers: agent.mcp_servers,
              model_config: agent.model_config,
              response_format: agent.response_format,
              agent_class_name: agent.agent_class_name,
              telemetry_agent_class: agent.telemetry_agent_class
            )
          end

          json
        end

        def version_json(version, include_diff: false)
          json = {
            id: version.id,
            version_number: version.version_number,
            change_summary: version.change_summary,
            created_by: version.created_by,
            created_at: version.created_at,
            is_latest: version.latest?
          }

          if include_diff && version.previous
            json[:diff] = version.diff(version.previous)
          end

          json
        end

        def default_appearance_for(preset)
          appearances = {
            "terminal" => { hat: "fedora", heldItem: "terminal", theme: "emerald" },
            "webDeveloper" => { hat: "safari", heldItem: "browser", theme: "blue" },
            "documentAnalysis" => { hat: "fedora", heldItem: "document", theme: "amber" },
            "writing" => { hat: "fedora", hatAccessory: "feather", heldItem: "scroll", theme: "purple" },
            "research" => { hat: "safari", heldItem: "magnifyingGlass", theme: "teal" },
            "playwright" => { hat: "fedora", hatAccessory: "theaterMasks", heldItem: "browser", theme: "rose" }
          }
          appearances[preset] || { theme: "default" }
        end

        def suggested_tools_for(preset)
          tools = {
            "terminal" => %w[terminal filesystem code],
            "webDeveloper" => %w[terminal filesystem code playwright],
            "documentAnalysis" => %w[filesystem search],
            "writing" => %w[edit translate],
            "research" => %w[fetch search memory],
            "playwright" => %w[playwright filesystem]
          }
          tools[preset] || []
        end

        def suggested_instructions_for(preset)
          instructions = {
            "terminal" => %w[github docker kubernetes],
            "webDeveloper" => %w[github ruby rails typescript],
            "research" => %w[github python],
            "playwright" => %w[github typescript]
          }
          instructions[preset] || []
        end
      end
    end
  end
end
