# frozen_string_literal: true

module ActionAgent
  # Base class for all Dashboard engine jobs.
  #
  # No blanket retry_on: the engine's jobs are not idempotent. An agent run
  # that fails after real provider work would be re-executed (and re-billed)
  # on every retry, flipping the run's status failed -> running -> failed
  # and overwriting its timings, after the UI had already stopped polling on
  # the first failure. Jobs that can safely retry declare it themselves, for
  # the specific transient errors they can tolerate.
  class ApplicationJob < ActiveJob::Base
    # Discard jobs for records that no longer exist
    discard_on ActiveRecord::RecordNotFound
  end
end
