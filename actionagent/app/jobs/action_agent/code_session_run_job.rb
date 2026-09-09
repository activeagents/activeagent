# frozen_string_literal: true

module ActionAgent
  # Runs the coding agent once, headlessly, and records what it produced.
  #
  # One run is one execution against a provider, which is why the controller
  # meters before enqueueing rather than here: a job that fails to start
  # must not be free, and a job that retries must not be charged twice.
  class CodeSessionRunJob < ApplicationJob
    queue_as :sandboxes

    def perform(code_session_id, prompt = nil)
      session = CodeSession.find(code_session_id)
      return if session.stopped? || session.expired?

      task = prompt.presence || session.task.to_s
      session.update!(status: :running, last_activity_at: Time.current)
      session.append_event(kind: "run", label: "#{session.tool_name} running", status: "started")

      result = CodeSessionOrchestrator.new(backend: session.backend).run(session, prompt: task)
      succeeded = result[:exit_code].to_i.zero?

      session.update!(
        status: succeeded ? :completed : :failed,
        transcript: result[:transcript],
        exit_code: result[:exit_code],
        input_tokens: result[:input_tokens] || session.input_tokens,
        output_tokens: result[:output_tokens] || session.output_tokens,
        cost: estimated_cost(session, result) || session.cost,
        completed_at: Time.current,
        last_activity_at: Time.current,
        error_message: succeeded ? nil : "The coding agent exited #{result[:exit_code]}"
      )
      session.append_event(
        kind: "run",
        label: succeeded ? "Run finished" : "Run failed (exit #{result[:exit_code]})",
        status: succeeded ? "done" : "error",
        duration_ms: result[:duration_ms]
      )
      broadcast(session)
    rescue StandardError => e
      fail_session(session, e)
      raise
    end

    private

    # Only when the tool actually printed its usage; most do not, and a
    # guessed cost is worse than no cost.
    def estimated_cost(session, result)
      return nil if result[:input_tokens].nil? && result[:output_tokens].nil?

      ModelPricing.estimate(
        model: session.model.presence || default_model(session),
        input_tokens: result[:input_tokens].to_i,
        output_tokens: result[:output_tokens].to_i
      )
    rescue StandardError
      nil
    end

    def default_model(session)
      case session.catalog_entry&.provider
      when "anthropic" then "claude-sonnet-4-5"
      when "openai" then "gpt-5"
      end
    end

    def fail_session(session, error)
      return if session.nil?

      message = error.message.to_s.truncate(1_000)
      session.update!(status: :failed, error_message: message, completed_at: Time.current)
      session.append_event(kind: "run", label: "Run failed", status: "error", detail: message)
      broadcast(session)
    rescue StandardError => e
      Rails.logger.error("[ActionAgent] could not record code session run failure: #{e.message}")
    end

    def broadcast(session)
      ActionCable.server.broadcast(
        "code_session_#{session.session_id}",
        { type: "run_complete", session: session.as_json_summary }
      )
    rescue StandardError => e
      Rails.logger.debug { "[ActionAgent] code session broadcast skipped: #{e.message}" }
    end
  end
end
