# frozen_string_literal: true

module ActionAgent
  # A GitHub App webhook delivery the dashboard accepted, by its
  # X-GitHub-Delivery id. Api::GithubAppWebhooksController records one before
  # it enqueues the delivery's GithubWebhookJob, so a redelivery of the same
  # id (from GitHub's retry or its Redeliver button) finds it and is a no-op:
  # a replayed +suspend+ cannot undo a later +unsuspend+.
  #
  # A row instead of Rails.cache: the unique index makes the check and the
  # record one atomic insert across every web process, whatever cache store
  # the host runs. Rows hold no payload and are pruned after RETENTION, a
  # little longer than GitHub keeps a delivery redeliverable.
  #
  # Not owned: a delivery is about an installation, whichever owner (if any)
  # linked it.
  class GithubWebhookDelivery < ApplicationRecord
    RETENTION = 7.days

    validates :delivery_id, :event, presence: true

    # Records the delivery, and answers whether it is the first time this id
    # was seen. Rows older than RETENTION are pruned on the way.
    #
    # @return [Boolean] false for a redelivery
    def self.record!(delivery_id:, event:, event_action: nil, installation_id: nil)
      where(created_at: ...RETENTION.ago).delete_all

      # A savepoint, so a duplicate inside a caller's transaction does not
      # abort it on PostgreSQL.
      transaction(requires_new: true) do
        create!(delivery_id: delivery_id, event: event, event_action: event_action, installation_id: installation_id)
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    # Forgets the delivery, so GitHub's redelivery of it is processed. For a
    # delivery that was recorded but could not be enqueued.
    def self.forget!(delivery_id)
      where(delivery_id: delivery_id).delete_all
    end
  end
end
