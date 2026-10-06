# frozen_string_literal: true

module ActionAgent
  # Walks a project's app with the explorer agent for one pending explorer
  # Exploration (see Api::ProjectExplorationsController and
  # ExplorerExecutionService), then records how it ended:
  #
  #   - the explorer finished, ran out of budget or was stopped: the run is
  #     complete and the exploration moves to review with its candidates
  #   - anything else went wrong: the run and the exploration fail, and the
  #     exploration keeps the candidates it found
  #
  # A browser the start launched for the walk is stopped afterwards, which
  # completes its recording and stops its minutes. That includes a walk that
  # never began, because it was stopped before the job ran or its run is
  # gone.
  class ExplorationJob < ApplicationJob
    queue_as :agents

    def perform(exploration_id, stop_browser = false)
      exploration = Exploration.find_by(id: exploration_id)
      return unless exploration&.source == "explorer"

      begin
        begin_walk(exploration)
      ensure
        stop(exploration) if stop_browser
      end
    end

    private

    def begin_walk(exploration)
      return unless exploration.status == "pending"

      run = exploration.agent_run
      return exploration.fail_walk!("The explorer's run is missing") if run.nil? || run.finished?

      exploration.start_walk!
      run.update!(status: :running, started_at: Time.current)
      walk(exploration, run)
    end

    def walk(exploration, run)
      result = ExplorerExecutionService.new(exploration, run).walk!
      complete(run, result[:output], result)
      exploration.finish_walk!(reason: result[:stop_reason])
    rescue ExplorerExecutionService::WalkCutShort => e
      complete(run, e.message, {})
      exploration.finish_walk!(reason: e.reason)
    rescue StandardError => e
      message = SecretScrubber.scrub(e.message, exploration.scrub_secrets)
      run.update!(status: :failed, completed_at: Time.current, error_message: message,
        output_metadata: run.output_metadata.to_h.merge("error_class" => e.class.name))
      exploration.fail_walk!(message)
    ensure
      run.broadcast_update
    end

    def complete(run, output, result)
      run.update!(
        output: output,
        output_metadata: result[:metadata].to_h.merge("stop_reason" => result[:stop_reason], "summary" => result[:summary]).compact,
        status: :complete,
        completed_at: Time.current,
        duration_ms: ((Time.current - run.started_at) * 1000).to_i,
        input_tokens: result.dig(:usage, :input_tokens),
        output_tokens: result.dig(:usage, :output_tokens),
        total_tokens: result.dig(:usage, :total_tokens)
      )
    end

    def stop(exploration)
      sandbox = exploration.sandbox_session&.reload
      SandboxBrowser.stop(sandbox) if sandbox && SandboxBrowser::STARTED.include?(sandbox.browser_status)
    rescue SandboxBrowser::Error => e
      Rails.logger.warn("[ActionAgent] exploration #{exploration.id}: could not stop the browser it started: #{e.message}")
    end
  end
end
