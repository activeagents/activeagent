# frozen_string_literal: true

module ActionAgent
  module Api
    # Starting an evaluation run on the caller's behalf, shared by the
    # evaluations API (POST /api/evaluations/:id/run) and the MCP facade's
    # `evaluations_run` tool so both check a run the same way.
    #
    # A scenario suite accepts a selection that narrows the run:
    #   - scenario_ids:  the scenarios to replay, by id
    #   - keys:          the scenarios to replay, by key
    #   - group:         one scenario group
    #   - models:        the candidate models, as an array or a comma-separated string
    #   - sandbox_id:    a checkout sandbox of the caller's that every replay reaches (see RunSandbox)
    module EvaluationRunStarting
      extend ActiveSupport::Concern

      include RunSandbox

      private

      # Starts a run of +evaluation+ and returns it. A scenario suite replays
      # through the provider once per scenario and model, so it runs in the
      # background and the run comes back pending. A generation-sampling
      # evaluation scores recorded data and finishes inline.
      #
      # A failure is recorded on the run rather than raised, so the caller
      # always gets a run to report.
      #
      # @return [EvaluationRun]
      def start_evaluation_run(evaluation, selection)
        return evaluation.run_later!(**selection) if evaluation.scenario_suite?

        evaluation.run!
      rescue StandardError => e
        Rails.logger.warn(
          "[ActionAgent] evaluation #{evaluation.id} run failed: #{e.class}: #{e.message}"
        )
        # EvaluationRunnerService records the failure on the run before
        # re-raising. A failure before the run record existed is recorded here.
        evaluation.evaluation_runs.recent.first ||
          evaluation.evaluation_runs.create!(status: :failed, error_message: e.message, completed_at: Time.current)
      end

      # Returns the selection +source+ (params or tool arguments) asks for,
      # without the sandbox, which evaluation_run_sandbox checks separately.
      def evaluation_run_selection(source)
        models = source[:models]
        models = models.to_s.split(",") unless models.is_a?(Array)

        {
          scenario_ids: Array(source[:scenario_ids]).map(&:to_s).reject(&:blank?),
          keys: Array(source[:keys]).map(&:to_s).reject(&:blank?),
          group: source[:group].to_s.presence,
          models: models.map(&:to_s).map(&:strip).reject(&:blank?)
        }.compact_blank
      end

      # Returns the checked sandbox +sandbox_id+ names for a run of
      # +evaluation+, or nil when none was asked for. Raises RunSandbox::Refused.
      #
      # Only a scenario suite's own replay executes the agent: a sampling run
      # scores recorded generations, and a host adapter replays in the host's
      # runtime, where no dashboard dispatcher runs.
      #
      # @return [SandboxSession, nil]
      def evaluation_run_sandbox(evaluation, sandbox_id)
        return nil if sandbox_id.blank?

        unless evaluation.scenario_suite?
          raise RunSandbox::Refused, "Only a scenario evaluation runs the agent; this one scores recorded generations, " \
            "so it cannot run against a sandbox"
        end
        if scenario_evaluation_adapter?(evaluation)
          raise RunSandbox::Refused, "This install replays scenarios through its own adapter, which cannot reach a " \
            "dashboard sandbox"
        end

        run_sandbox_for(evaluation.agent, sandbox_id)
      end

      # Whether a run of +evaluation+ cannot replay its scenarios: its agent
      # is observed (read-only), and no host adapter replays it instead.
      def unexecutable_scenario_run?(evaluation)
        evaluation.agent.observed? && !scenario_evaluation_adapter?(evaluation)
      end

      def scenario_evaluation_adapter?(evaluation)
        ActionAgent.scenario_evaluation_adapter_resolver&.call(evaluation).respond_to?(:call)
      end
    end
  end
end
