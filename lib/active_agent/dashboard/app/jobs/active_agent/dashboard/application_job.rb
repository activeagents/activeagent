# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Base class for all Dashboard engine jobs.
    class ApplicationJob < ActiveJob::Base
      # Retry failed jobs
      retry_on StandardError, wait: :polynomially_longer, attempts: 3

      # Discard jobs for records that no longer exist
      discard_on ActiveRecord::RecordNotFound
    end
  end
end
