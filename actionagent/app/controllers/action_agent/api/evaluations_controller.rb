# frozen_string_literal: true

module ActionAgent
  module Api
    # CRUD + execution for agent evaluations, backing the dashboard
    # Evaluations view. Scoped to the current user's agents.
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
        evaluations = scope.includes(:agent, :evaluation_runs).recent.limit(50)

        render json: { evaluations: evaluations.map { |evaluation| serialize(evaluation) } }
      end

      # GET /api/evaluations/:id
      def show
        evaluation = evaluations_scope.find(params[:id])

        render json: {
          evaluation: serialize(evaluation).merge(
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

        if evaluation.save
          evaluation.run!
          render json: { evaluation: serialize(evaluation.reload) }, status: :created
        else
          render json: { errors: evaluation.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # POST /api/evaluations/:id/run
      def run
        evaluation = evaluations_scope.find(params[:id])
        run = evaluation.run!

        render json: { evaluation: serialize(evaluation.reload), run: serialize_run(run) }
      end

      # DELETE /api/evaluations/:id
      def destroy
        evaluations_scope.find(params[:id]).destroy!
        head :no_content
      end

      private

      def evaluations_scope
        Evaluation.joins(:agent).where(agent: owner_agents)
      end

      def evaluation_params
        params.require(:evaluation).permit(:agent_id, :name, :judge_kind, :judge_model, :sample_size)
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
        Array(params[:evaluation][:compare_models]).map(&:to_s).reject(&:blank?)
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
          created_at: evaluation.created_at.iso8601,
          latest_run: latest ? serialize_run(latest) : nil
        }
      end

      def serialize_run(run)
        {
          id: run.id,
          status: run.status,
          scores: run.scores,
          average_score: run.average_score,
          samples_evaluated: run.samples_evaluated,
          samples_passed: run.samples_passed,
          error_message: run.error_message,
          completed_at: run.completed_at&.iso8601,
          created_at: run.created_at.iso8601
        }
      end
    end
  end
end
