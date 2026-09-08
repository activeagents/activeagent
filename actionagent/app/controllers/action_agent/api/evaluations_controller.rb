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
      before_action :require_owner!

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
      def index
        scope = evaluations_scope
        scope = scope.where(agent_id: params[:agent_id]) if params[:agent_id].present?
        evaluations = scope.includes(:agent, :evaluation_runs, :scenarios).recent.limit(50)

        render json: { evaluations: evaluations.map { |evaluation| serialize(evaluation) } }
      end

      # GET /api/evaluations/:id
      def show
        evaluation = evaluations_scope.find(params[:id])

        render json: {
          evaluation: serialize(evaluation).merge(
            scenarios: evaluation.scenarios.ordered.map(&:as_json_summary),
            runs: evaluation.evaluation_runs.recent.limit(20).map { |run| serialize_run(run) }
          )
        }
      end

      # POST /api/evaluations
      def create
        agent = owner_agents.find(params.require(:evaluation)[:agent_id])

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
          start_run(evaluation, selection_params) unless params[:evaluation][:run] == false || params[:evaluation][:run] == "false"
          render json: { evaluation: serialize(evaluation.reload) }, status: :created
        else
          render json: { errors: evaluation.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/evaluations/:id/run
      # A scenario suite accepts a selection: scenario_ids[], keys[], group,
      # models[] (or a comma-separated `models` string).
      def run
        evaluation = evaluations_scope.find(params[:id])
        run = start_run(evaluation, selection_params)

        render json: { evaluation: serialize(evaluation.reload), run: serialize_run(run) }
      end

      # GET /api/evaluations/:id/runs/:run_id
      # One run in full: its per-scenario, per-model results alongside the
      # scenarios, so the matrix and every answer can be rendered.
      def show_run
        evaluation = evaluations_scope.find(params[:id])
        run = evaluation.evaluation_runs.find(params[:run_id])
        results = run.scenario_results.includes(:scenario).joins(:scenario)
          .order(EvaluationScenario.arel_table[:position], EvaluationScenario.arel_table[:id], :model)

        render json: {
          evaluation: serialize(evaluation),
          run: serialize_run(run).merge(results: results.map(&:as_json_summary))
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

      # DELETE /api/evaluations/:id
      def destroy
        evaluations_scope.find(params[:id]).destroy!
        head :no_content
      end

      private

      # A scenario suite replays through the provider once per scenario and
      # model, so it runs in the background; a generation-sampling evaluation
      # scores recorded data and finishes inline.
      def start_run(evaluation, selection)
        return evaluation.run_later!(**selection) if evaluation.scenario_suite?

        # EvaluationRunnerService marks the run failed with the error message
        # and then re-raises. Letting that escape returned an HTML 500 for a
        # request that had already persisted the evaluation and its failed
        # run: the client saw a JSON parse error, the form stayed open, and a
        # resubmit failed on the now-taken name. The failure is on the run
        # record, which is what the response carries.
        evaluation.run!
      rescue StandardError => e
        Rails.logger.warn(
          "[ActionAgent] evaluation #{evaluation.id} run failed: #{e.class}: #{e.message}"
        )
        # The service records the failure before re-raising; a failure that
        # predates the run record (creating it, say) is recorded here so the
        # response always carries one.
        evaluation.evaluation_runs.recent.first ||
          evaluation.evaluation_runs.create!(status: :failed, error_message: e.message, completed_at: Time.current)
      end

      def evaluations_scope
        Evaluation.joins(:agent).where(agent: owner_agents)
      end

      def evaluation_params
        params.require(:evaluation).permit(:agent_id, :name, :judge_kind, :judge_model, :sample_size)
      end

      def scenario_params
        params.require(:scenario).permit(:prompt, :group, :notes, :enabled, :key, expectations: {})
      end

      # scenario_ids, keys, group and models narrow a scenario run. `models`
      # may arrive as an array or as the comma-separated field the form posts.
      def selection_params
        source = params[:evaluation].is_a?(ActionController::Parameters) && params[:evaluation].key?(:selection) ? params[:evaluation][:selection] : params
        models = source[:models]
        models = models.to_s.split(",") unless models.is_a?(Array)

        {
          scenario_ids: Array(source[:scenario_ids]).map(&:to_s).reject(&:blank?),
          keys: Array(source[:keys]).map(&:to_s).reject(&:blank?),
          group: source[:group].to_s.presence,
          models: models.map(&:to_s).map(&:strip).reject(&:blank?)
        }.compact_blank
      end

      # Scenarios from the request: a pasted text block, a list of objects, or
      # nothing (a generation-sampling evaluation).
      def scenario_attributes
        source = params[:evaluation].presence || params
        text = source[:scenarios_text].to_s
        list = source[:scenarios]

        if list.present?
          list = list.to_unsafe_h.values if list.is_a?(ActionController::Parameters)
          ActiveAgent::Evals::ScenarioParser.parse(Array(list).map { |entry| entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry }.to_json)
        elsif text.present?
          ActiveAgent::Evals::ScenarioParser.parse(text)
        else
          []
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

      def serialize(evaluation)
        latest = evaluation.latest_run

        {
          id: evaluation.id,
          name: evaluation.name,
          agent: { id: evaluation.agent.id, name: evaluation.agent.name, slug: evaluation.agent.slug },
          judge_kind: evaluation.judge_kind,
          judge_model: evaluation.judge_model,
          criteria: evaluation.criteria,
          compare_models: evaluation.compare_models,
          config: evaluation.config,
          sample_size: evaluation.sample_size,
          scenario_suite: evaluation.scenario_suite?,
          scenario_count: evaluation.scenarios.size,
          scenario_groups: evaluation.scenario_suite? ? evaluation.scenario_groups : [],
          created_at: evaluation.created_at.iso8601,
          latest_run: latest ? serialize_run(latest) : nil
        }
      end

      def serialize_run(run)
        {
          id: run.id,
          status: run.status,
          scores: run.scores,
          selection: run.selection,
          models: run.models,
          average_score: safe_average_score(run),
          samples_evaluated: run.samples_evaluated,
          samples_passed: run.samples_passed,
          usage: run.usage,
          error_message: run.error_message,
          completed_at: run.completed_at&.iso8601,
          created_at: run.created_at.iso8601
        }
      end

      # index serializes the latest run of every listed evaluation, so an
      # unaverageable scores payload used to 500 the entire Evaluations page
      # instead of degrading that one run's headline number.
      def safe_average_score(run)
        run.average_score
      rescue StandardError => e
        Rails.logger.warn(
          "[ActionAgent] evaluation run #{run.id} average_score failed: #{e.class}: #{e.message}"
        )
        nil
      end
    end
  end
end
