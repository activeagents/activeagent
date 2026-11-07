# frozen_string_literal: true

module ActionAgent
  # Fails the runs whose lease ran out (AgentRun.expire_lost!): running, with
  # no claim, renewal or result from their worker within
  # ActionAgent.run_lease_duration. A run's own page and the run list fail
  # the lost runs they reach; this job reaches the rest. It never executes a
  # run again.
  #
  # Not scheduled by default. To schedule it:
  #
  #   # config/recurring.yml
  #   agent_run_expiry:
  #     class: ActionAgent::AgentRunExpiryJob
  #     schedule: every 5 minutes
  class AgentRunExpiryJob < ApplicationJob
    queue_as :default

    def perform
      AgentRun.expire_lost!
    end
  end
end
