# frozen_string_literal: true

module ActionAgent
  # Prunes telemetry traces past the configured retention window.
  #
  # NOT SCHEDULED BY DEFAULT: deleting trace history is a decision for the
  # app that owns the data. To enable it, set a window and schedule the job:
  #
  #   ActionAgent.trace_retention = 30.days
  #
  #   # config/recurring.yml
  #   trace_retention:
  #     class: ActionAgent::TraceRetentionJob
  #     schedule: every day at 4am
  #
  # A host app with per-tenant retention rules (the activeagents.ai platform
  # prunes per plan) passes a callable instead, receiving each owner and
  # returning that owner's window.
  class TraceRetentionJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 5_000

    def perform
      window = ActionAgent.trace_retention
      return if window.nil?

      if ActionAgent.multi_tenant? && (owners = ActionAgent.owner_class)
        owners.find_each { |owner| prune(traces.for_account(owner), window_for(window, owner)) }
      else
        prune(traces.all, window_for(window, nil))
      end
    end

    private

    def traces
      ActionAgent.trace_model
    end

    def window_for(window, owner)
      window.respond_to?(:call) ? window.call(owner) : window
    end

    # Deletes in batches so a long-neglected install doesn't build one
    # enormous statement.
    def prune(scope, window)
      return if window.nil?

      cutoff = window.ago
      loop do
        deleted = scope.where(timestamp: ...cutoff).limit(BATCH_SIZE).delete_all
        break if deleted < BATCH_SIZE
      end
    end
  end
end
