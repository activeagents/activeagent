# frozen_string_literal: true

module ActionAgent
  module Api
    # CRUD + execution for agent evaluations, backing the dashboard
    # Evaluations view. Scoped to the current user's agents.
    #
    # An evaluation created with scenarios (a pasted list of user messages)
    # is a scenario suite: runs replay the scenarios through the agent rather
    # than sampling recorded generations, and can be narrowed to a group, to
    # specific scenarios, or to specific models.
    class EvaluationsController < BaseController
      include EvaluationRunStarting

      rescue_from ActiveAgent::Evals::ScenarioParser::ParseError do |error|
        render json: { errors: [ error.message ] }, status: :unprocessable_entity
      end

      before_action :require_owner!
      # A scenario suite replays its prompts through the provider, so creating
      # one that runs, or running one, executes the agent and is gated the way
      # AgentsController#execute is: the dashboard's execution switch, no
      # observed (read-only) agents, and the owner's execution quota. Each
      # replay then counts as one execution (ScenarioEvaluationRunner#replay).
      before_action :require_execution_enabled!, :require_executable_scenario_agent!, :enforce_execution_quota!,
                    only: [ :create, :run ], if: :replays_scenarios?

      # Default criteria used when none are supplied — all rule-based, so a
      # new evaluation produces real scores without provider credentials.
      DEFAULT_CRITERIA = [
        { "key" => "response_present", "type" => "response_present", "config" => {} },
        { "key" => "response_length", "type" => "min_length", "config" => { "chars" => 40 } },
        { "key" => "latency", "type" => "max_latency_ms", "config" => { "ms" => 5000 } },
        { "key" => "token_budget", "type" => "token_budget", "config" => { "output_tokens" => 1000 } }
      ].freeze

      # GET /api/evaluations
      # agent_id scopes to one agent. The filter has to happen before the limit:
      # the agent page reads this endpoint, and filtering an account-wide page of
      # 50 client-side hides an agent whose evaluations are not among the account's
      # 50 most recent. The scope is already restricted to the current user's
      # agents, so an id outside it simply returns nothing.
      #
      # Three fields feed the dashboard's model pickers. They describe the
      # credentials of #picker_credentials_owner:
      #   - judge_provider:        the provider a judge model runs on, null
      #                            when none has credentials or the lookup
      #                            raised
      #   - judge_provider_error:  true when that lookup raised, as it does
      #                            when a stored key no longer decrypts
      #   - model_providers:       the providers agent runs have credentials
      #                            for, leaving out any whose credentials
      #                            cannot be read
      def index
        scope = evaluations_scope
        scope = scope.where(agent_id: params[:agent_id]) if params[:agent_id].present?
        evaluations = scope.includes(:agent, :evaluation_runs, :scenarios).recent.limit(50)
        owner = picker_credentials_owner

        render json: {
          evaluations: evaluations.map { |evaluation| serialize(evaluation) },
          **judge_provider_fields(owner),
          model_providers: AgentExecutionService.available_providers(owner)
        }
      end

      # Runs listed per evaluation on GET /api/evaluations/:id. The rest of
      # the history stays reachable by run id; `run_count` says how long it is.
      RUN_HISTORY_LIMIT = 20

      # GET /api/evaluations/:id
      def show
        evaluation = evaluations_scope.find(params[:id])
        run_count = evaluation.evaluation_runs.count
        runs = evaluation.evaluation_runs.recent.limit(RUN_HISTORY_LIMIT).to_a

        render json: {
          evaluation: serialize(evaluation).merge(
            scenarios: evaluation.scenarios.ordered.map(&:as_json_summary),
            runs: runs.each_with_index.map { |run, index| serialize_run(run, number: run_count - index) }
          )
        }
      end

      # POST /api/evaluations
      def create
        agent = requested_agent

        judge_kind = evaluation_params[:judge_kind].presence || "rules"
        config = {}
        config["compare_models"] = compare_models_param if compare_models_param.any?
        scenarios = scenario_attributes

        evaluation = agent.evaluations.new(
          name: evaluation_params[:name],
          judge_kind: judge_kind,
          judge_model: evaluation_params[:judge_model],
          sample_size: evaluation_params[:sample_size].presence || 20,
          # judge_defined starts with no criteria — the judge authors the
          # KPIs on the first run.
          criteria: judge_kind == "judge_defined" ? explicit_criteria : normalized_criteria,
          config: config
        )
        scenarios.each_with_index do |attrs, index|
          evaluation.scenarios.build(
            key: attrs["key"], prompt: attrs["prompt"], group: attrs["group"], notes: attrs["notes"],
            expectations: attrs["expectations"] || {}, position: attrs.fetch("position", index)
          )
        end

        if evaluation.save
          start_evaluation_run(evaluation, selection_params) if run_requested?
          render json: { evaluation: serialize(evaluation.reload) }, status: :created
        else
          render json: { errors: evaluation.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/evaluations/:id/run
      # A scenario suite accepts a selection: scenario_ids[], keys[], group,
      # models[] (or a comma-separated `models` string), and `sandbox_id`: a
      # checkout sandbox of the caller's whose app runtime every replay of
      # this run reaches as well, without the agent being edited (see
      # RunSandbox). The run records which one it used.
      def run
        evaluation = current_evaluation
        selection = selection_params
        if (sandbox = evaluation_run_sandbox(evaluation, requested_sandbox_id))
          selection[:sandbox_id] = sandbox.session_id
        end
        run = start_evaluation_run(evaluation, selection)
        evaluation.reload

        render json: {
          evaluation: serialize(evaluation),
          run: serialize_run(run, number: evaluation.evaluation_runs.count)
        }
      end

      # GET /api/evaluations/:id/runs/:run_id
      # One run in full: its per-scenario, per-model results alongside the
      # scenarios, so the matrix and every answer can be rendered, and its
      # fix items — the faults grouped with the tools, MCP server and
      # dashboard action that address each. Fix item paths are relative to
      # the mount: the React app resolves them itself (dashboardPath).
      def show_run
        evaluation = evaluations_scope.find(params[:id])
        run = evaluation.evaluation_runs.find(params[:run_id])
        results = run.scenario_results.includes(:scenario).joins(:scenario)
          .order(EvaluationScenario.arel_table[:position], EvaluationScenario.arel_table[:id], :model)

        render json: {
          evaluation: serialize(evaluation),
          run: serialize_run(run, number: run_number(evaluation, run))
            .merge(results: results.map(&:as_json_summary), fix_items: safe_fix_items(run))
        }
      end

      # GET /api/evaluations/:id/scenarios
      def scenarios
        evaluation = evaluations_scope.find(params[:id])

        render json: {
          scenarios: evaluation.scenarios.ordered.map(&:as_json_summary),
          groups: evaluation.scenario_groups
        }
      end

      # PUT /api/evaluations/:id/scenarios
      # Replaces the suite from pasted text (`scenarios_text`) or a list
      # (`scenarios`). Scenarios whose key survives keep their results.
      def replace_scenarios
        evaluation = evaluations_scope.find(params[:id])
        attributes = scenario_attributes
        return render json: { errors: [ "No scenarios found in the pasted text" ] }, status: :unprocessable_entity if attributes.empty?

        evaluation.replace_scenarios!(attributes)

        render json: {
          evaluation: serialize(evaluation.reload),
          scenarios: evaluation.scenarios.ordered.map(&:as_json_summary),
          groups: evaluation.scenario_groups
        }
      end

      # PATCH /api/evaluations/:id/scenarios/:scenario_id
      def update_scenario
        evaluation = evaluations_scope.find(params[:id])
        scenario = evaluation.scenarios.find(params[:scenario_id])
        scenario.update!(scenario_params)

        render json: { scenario: scenario.as_json_summary }
      end

      # DELETE /api/evaluations/:id/scenarios/:scenario_id
      def destroy_scenario
        evaluation = evaluations_scope.find(params[:id])
        evaluation.scenarios.find(params[:scenario_id]).destroy!
        head :no_content
      end

      # GET /api/evaluations/:id/runs/:run_id/report?theme=dark
      #
      # The run as the framework's self-contained HTML report page — the
      # in-dashboard view and, because the page is a single file, the export.
      # `theme` (light|dark) pins the palette to the dashboard's; without it
      # the page follows the viewer's own preference. The page is served
      # outside the React app, so its fix item actions link at the absolute
      # mount path (request.script_name) rather than relative to it.
      def run_report
        evaluation = evaluations_scope.find(params[:id])
        run = evaluation.evaluation_runs.find(params[:run_id])
        raise ActiveRecord::RecordNotFound unless evaluation.scenario_suite?

        report = run.to_report(links: run.report_links(mount: request.script_name))

        render html: report.to_html(theme: params[:theme]).html_safe, layout: false
      end

      # DELETE /api/evaluations/:id
      def destroy
        evaluations_scope.find(params[:id]).destroy!
        head :no_content
      end

      private

      # Returns whose credentials the index's model picker fields describe.
      # Agent runs and their judge use the evaluated agent's owner's
      # credentials, so a list scoped to one agent reads that agent's owner,
      # and an unscoped list the signed-in owner.
      def picker_credentials_owner
        agent = owner_agents.find_by(id: params[:agent_id]) if params[:agent_id].present?
        agent ? agent.owner : current_owner
      end

      # Returns the index's judge_provider and judge_provider_error for
      # +owner+. A lookup that raises, from a key that no longer decrypts or a
      # host credentials hook that fails, is logged and reported as an error.
      def judge_provider_fields(owner)
        { judge_provider: EvaluationRunnerService.judge_provider_for(owner)&.to_s, judge_provider_error: false }
      rescue StandardError => e
        Rails.logger.warn("[Evaluations] judge provider lookup failed: #{e.class}: #{e.message}")
        { judge_provider: nil, judge_provider_error: true }
      end

      def evaluations_scope
        Evaluation.joins(:agent).where(agent: owner_agents)
      end

      def current_evaluation
        @current_evaluation ||= evaluations_scope.find(params[:id])
      end

      def requested_agent
        @requested_agent ||= owner_agents.find(params.require(:evaluation)[:agent_id])
      end

      # create runs the new evaluation unless told not to.
      def run_requested?
        run = params.require(:evaluation)[:run]
        run != false && run != "false"
      end

      # Whether this request replays scenarios through the agent: running a
      # scenario suite, or creating an evaluation with scenarios that runs.
      def replays_scenarios?
        case action_name
        when "run" then current_evaluation.scenario_suite?
        when "create" then run_requested? && scenario_attributes.any?
        else false
        end
      end

      # Observed agents cannot use the engine's execution service. A persisted
      # evaluation with an explicit host adapter runs in that source instead.
      def require_executable_scenario_agent!
        agent = action_name == "create" ? requested_agent : current_evaluation.agent
        return unless agent.observed?
        return if action_name == "run" && !unexecutable_scenario_run?(current_evaluation)

        render json: {
          error: "Observed agents are read-only — duplicate this agent to create an executable copy"
        }, status: :unprocessable_entity
      end

      def evaluation_params
        params.require(:evaluation).permit(:agent_id, :name, :judge_kind, :judge_model, :sample_size)
      end

      def scenario_params
        params.require(:scenario).permit(:prompt, :group, :notes, :enabled, :key, expectations: {})
      end

      # The sandbox id a run was asked to use, from the selection or the top
      # level of the request.
      def requested_sandbox_id
        selection_source[:sandbox_id].presence || params[:sandbox_id].presence
      end

      def selection_params
        evaluation_run_selection(selection_source)
      end

      def selection_source
        params[:evaluation].is_a?(ActionController::Parameters) && params[:evaluation].key?(:selection) ? params[:evaluation][:selection] : params
      end

      # Scenarios from text, a YAML/JSON suite, or a list of objects. Production
      # questions are selected at import time, only on explicit opt-in; the
      # persisted scenario records do not store an environment flag.
      def scenario_attributes
        @scenario_attributes ||= begin
          source = params[:evaluation].presence || params
          text = source[:scenarios_text].to_s
          list = source[:scenarios]
          include_production_only = ActiveModel::Type::Boolean.new.cast(source[:include_production_only]) == true

          imported = if list.present?
            list = list.to_unsafe_h.values if list.is_a?(ActionController::Parameters)
            serialized = Array(list).map { |entry| entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry }.to_json
            ActiveAgent::Evals::ScenarioParser.parse(serialized, include_production_only: include_production_only)
          elsif text.present?
            ActiveAgent::Evals::ScenarioParser.parse(text, include_production_only: include_production_only)
          else
            []
          end
          if (list.present? || text.present?) && imported.empty?
            raise ActiveAgent::Evals::ScenarioParser::ParseError, "No scenarios matched the import. Check the catalog or include_production_only selection."
          end
          imported
        end
      end

      def normalized_criteria
        explicit_criteria.presence || DEFAULT_CRITERIA.deep_dup
      end

      def explicit_criteria
        raw = params[:evaluation][:criteria]
        return [] if raw.blank?

        raw.map do |criterion|
          criterion.permit(:key, :type, config: {}).to_h.tap do |c|
            c["key"] = c["key"].presence || c["type"]
            c["config"] ||= {}
          end
        end
      end

      def compare_models_param
        models = params[:evaluation][:compare_models]
        models = models.to_s.split(",") unless models.is_a?(Array)
        models.map(&:to_s).map(&:strip).reject(&:blank?)
      end

      def serialize(evaluation) = EvaluationSerializer.evaluation(evaluation)

      def serialize_run(run, number: nil) = EvaluationSerializer.run(run, number: number)

      def run_number(evaluation, run) = EvaluationSerializer.run_number(evaluation, run)

      def safe_fix_items(run) = EvaluationSerializer.fix_items(run)
    end
  end
end
