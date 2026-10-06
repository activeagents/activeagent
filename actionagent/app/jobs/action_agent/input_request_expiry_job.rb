# frozen_string_literal: true

module ActionAgent
  # Expires the requests for input left unanswered past their `expires_at`,
  # and fails their runs (InputRequest.expire_overdue!). An answer, the
  # request list and a run's own page expire the requests they reach; this
  # job reaches the rest.
  #
  # Not scheduled by default. To schedule it:
  #
  #   # config/recurring.yml
  #   input_request_expiry:
  #     class: ActionAgent::InputRequestExpiryJob
  #     schedule: every 15 minutes
  class InputRequestExpiryJob < ApplicationJob
    queue_as :default

    def perform
      InputRequest.expire_overdue!
    end
  end
end
