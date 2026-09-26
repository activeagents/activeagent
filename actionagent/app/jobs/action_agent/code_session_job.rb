# frozen_string_literal: true

module ActionAgent
  # Runs one queued Claude Code session (CodeSession) through the sandbox
  # backend, storing its stream-json transcript as it arrives, then the
  # outcome Claude Code reported and the diff it left in the checkout.
  #
  # Not retried: a session edits the checkout and spends the owner's Claude
  # Code usage, so running it again is not the same as running it once.
  class CodeSessionJob < ApplicationJob
    queue_as :sandboxes

    # Longest error_message kept: a failed session's own report can be long.
    MAX_ERROR_MESSAGE = 2_000

    def perform(code_session_id)
      code_session = CodeSession.find_by(id: code_session_id)
      return unless code_session&.queued?
      # Claimed atomically: a session cancelled after it was loaded, or a
      # second job for the same one, finds it no longer queued.
      return unless start(code_session)

      # Computed once rather than per event: finding them reads the GitHub
      # connection and the Claude Code key.
      secrets = code_session.secrets
      result_event = nil
      stop_sent = false
      orchestrator = SandboxOrchestrator.new
      sandbox = code_session.sandbox_session

      # Queued behind a Stop (the cleanup job shares this queue): never start
      # Claude Code, with the owner's credential, in a stopped sandbox.
      unless sandbox.reload.ready? && sandbox.active?
        return fail!(code_session, "The sandbox was stopped before the session started")
      end

      outcome = orchestrator.run_code_session(sandbox, code_session) do |event|
        # append_event! reloads the row under its lock, so this sees a cancel
        # made since. The cancel's own stop can land after this job claimed
        # the session but before the backend started Claude Code, and then
        # has no process to stop; an event means the process exists now, so
        # the stop is sent again, once.
        code_session.append_event!(event, secrets: secrets)
        if code_session.cancelled? && !stop_sent
          stop_sent = true
          stop(orchestrator, sandbox, code_session)
        end
        next unless event.is_a?(Hash) && event["type"] == "result"

        result_event = event
        code_session.record_result!(event)
      end

      finish(code_session, outcome.to_h, result_event, secrets)
    rescue StandardError => e
      message = SecretScrubber.scrub(e.message.to_s, secrets || safe_secrets(code_session))
      Rails.logger.error("Claude Code session #{code_session_id} failed: #{message}")
      fail!(code_session, message) if code_session
    end

    private

    def start(code_session)
      now = Time.current
      claimed = CodeSession.where(id: code_session.id, status: CodeSession.statuses[:queued])
        .update_all(status: CodeSession.statuses[:running], started_at: now, updated_at: now)
      return false if claimed.zero?

      code_session.reload
    end

    # Under the row lock, which reloads the session: a cancel that landed
    # while it ran must not be overwritten by the outcome.
    def finish(code_session, outcome, result_event, secrets)
      code_session.with_lock do
        code_session.diff = outcome[:diff]

        if code_session.cancelled?
          # Settled now, with its diff (see CodeSession#diff_pending?).
          code_session.finished_at ||= Time.current
        elsif succeeded?(result_event, outcome)
          code_session.assign_attributes(status: :succeeded, finished_at: Time.current)
        else
          code_session.assign_attributes(
            status: :failed,
            error_message: failure_message(result_event, outcome, secrets),
            finished_at: Time.current
          )
        end
        code_session.save!
      end
    end

    # Claude Code reported success and the process agreed.
    def succeeded?(result_event, outcome)
      result_event.present? && !reported_error?(result_event) && outcome[:exit_status] == 0
    end

    # A result event reports a failure through is_error, or through an error
    # subtype (error_max_turns, error_during_execution): a session that ran
    # out of turns did not finish the task, whatever its is_error says.
    def reported_error?(result_event)
      result_event["is_error"] != false || (result_event["subtype"] || "success") != "success"
    end

    # What went wrong, in Claude Code's own words when it reported a failure
    # and from the process otherwise.
    def failure_message(result_event, outcome, secrets)
      message = reported_failure(result_event) || process_failure(result_event, outcome)
      SecretScrubber.scrub(message, secrets).truncate(MAX_ERROR_MESSAGE)
    end

    def reported_failure(result_event)
      return nil unless result_event && reported_error?(result_event)

      errors = Array(result_event["errors"]).map { |error| error.is_a?(Hash) ? (error["message"] || error.to_json) : error.to_s }
      result_event["result"].to_s.presence ||
        errors.join("; ").presence ||
        "Claude Code stopped: #{result_event['subtype']}"
    end

    def process_failure(result_event, outcome)
      status = outcome[:exit_status]
      headline =
        if !status.nil? && status != 0 then "Claude Code exited with status #{status}"
        elsif result_event.nil? then "Claude Code ended without reporting a result"
        else "Claude Code did not finish"
        end

      [ headline, outcome[:stderr_tail].to_s.strip.presence ].compact.join(": ")
    end

    def stop(orchestrator, sandbox, code_session)
      orchestrator.cancel_code_session(sandbox, code_session)
    rescue StandardError => e
      Rails.logger.warn("Failed to stop cancelled Claude Code session #{code_session.id}: #{e.message}")
    end

    # Settles a session that ended without an outcome from the backend: it
    # raised, refused to start Claude Code, or was never asked to. A session
    # cancelled meanwhile stays cancelled, but is settled too: no diff is
    # coming for it (see CodeSession#diff_pending?).
    def fail!(code_session, message)
      # A save that raised leaves unsaved changes behind, and locking a dirty
      # record raises: start from the row as stored.
      code_session.reload
      code_session.with_lock do
        if code_session.cancelled?
          code_session.update!(finished_at: Time.current) if code_session.finished_at.nil?
          next
        end
        next if code_session.finished?

        code_session.update!(status: :failed, error_message: message.truncate(MAX_ERROR_MESSAGE), finished_at: Time.current)
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def safe_secrets(code_session)
      code_session&.secrets || []
    rescue StandardError
      []
    end
  end
end
