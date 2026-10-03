# frozen_string_literal: true

module ActionAgent
  # Continues a run that paused for input, once every request of the pause
  # is answered or declined.
  #
  # Its only argument is the id of one of the pause's requests. The answers
  # are read and decrypted here, so none of them, `:secret` answers
  # included, is ever a job argument or reaches the queue's storage. Two
  # answers that settle a pause together each enqueue this job, and only the
  # first to take the run's lock resumes it.
  class AgentResumeJob < ApplicationJob
    queue_as :agents

    def perform(input_request_id)
      request = InputRequest.find_by(id: input_request_id)
      run = request&.subject
      return unless run.is_a?(AgentRun)

      pause = claim_pause(run, request)
      return unless pause

      segment_started_at = Time.current
      secrets = pause.select { |paused| paused.kind == "secret" }.filter_map(&:answer)

      begin
        result = AgentExecutionService.call(
          run.agent, run,
          resume: {
            checkpoint: request.checkpoint_data,
            answers: pause.to_h { |paused| [ paused.tool_call_id, paused.resume_answer ] },
            secrets: secrets
          }
        )

        run.unless_cancelled do
          run.record_result!(result, segment_started_at: segment_started_at)
          run.add_log(result[:input_requests].present? ? "Execution paused for input" : "Execution completed successfully", level: :info)
        end
      rescue => e
        message = ActiveAgent::InputRequest.scrub(e.message, secrets)
        run.unless_cancelled do
          run.record_failure!(e, message: message)
          run.add_log("Execution failed: #{message}", level: :error)
        end
      ensure
        forget_secret_answers(pause)
        run.broadcast_update
      end
    end

    private

    # Moves the run from awaiting_input to running when every request of the
    # pause is settled, under the run's row lock, and returns the pause's
    # requests in call order; nil when this job is not the one to resume it,
    # or when the request's pause is not the one the run waits on.
    def claim_pause(run, request)
      run.with_lock do
        next nil unless run.awaiting_input? && request.current_pause?

        pause = request.pause_requests.order(:id).to_a
        next nil unless pause.all? { |paused| paused.answered? || paused.declined? }

        run.update!(status: :running)
        pause
      end
    end

    # A secret answer has reached its tool once the resume ran, so it is not
    # kept any longer than that.
    def forget_secret_answers(pause)
      pause.select { |paused| paused.kind == "secret" && paused.answer.present? }.each do |paused|
        paused.update_columns(answer: nil)
      end
    end
  end
end
