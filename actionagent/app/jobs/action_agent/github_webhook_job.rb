# frozen_string_literal: true

module ActionAgent
  # Applies a GitHub App webhook delivery that Api::GithubAppWebhooksController
  # verified and recorded, so Settings -> Integrations learns of a change on
  # GitHub when it happens rather than when a token mint is next refused.
  #
  # +payload+ is the slice of the delivery GithubWebhookJob.payload_for keeps.
  # A delivery about an installation no owner linked changes nothing, and so
  # does an event or action not handled here.
  #
  # Each handler sets state from the payload rather than toggling it, so
  # running one twice leaves the same result; the delivery record is what
  # keeps an old delivery from being replayed over a newer one.
  class GithubWebhookJob < ApplicationJob
    queue_as :default

    EVENTS = %w[installation installation_repositories github_app_authorization].freeze

    # What the job needs from a delivery's +payload+, so the job's arguments
    # carry neither the sender's profile nor every repository's details.
    def self.payload_for(event, payload)
      installation = payload["installation"].is_a?(Hash) ? payload["installation"] : {}
      repositories = ->(key) { Array(payload[key]).filter_map { |repo| repo.slice("id", "full_name") if repo.is_a?(Hash) } }
      sender = payload["sender"].is_a?(Hash) ? payload["sender"] : {}

      {
        "action" => payload["action"].to_s,
        "installation" => installation.slice("id", "permissions", "repository_selection", "suspended_at"),
        "repositories_added" => event == "installation_repositories" ? repositories.call("repositories_added") : [],
        "repositories_removed" => event == "installation_repositories" ? repositories.call("repositories_removed") : [],
        "sender_id" => sender["id"]
      }
    end

    def perform(event, payload)
      case event
      when "installation" then installation(payload)
      when "installation_repositories" then installation_repositories(payload)
      when "github_app_authorization" then authorization(payload)
      end
    end

    private

    def installation(payload)
      record = linked_installation(payload) or return
      reported = payload["installation"]

      case payload["action"]
      when "deleted"
        record.update!(removed_at: Time.current) if record.removed_at.nil?
      when "suspend"
        record.update!(suspended_at: parse_time(reported["suspended_at"]) || Time.current)
      when "unsuspend"
        record.update!(suspended_at: nil)
      when "new_permissions_accepted"
        record.update!(permissions: reported["permissions"]) if reported["permissions"].is_a?(Hash)
      end
    end

    # The repository picker lists what the installation reaches from GitHub
    # each time it opens, so an added repository needs nothing stored; a
    # removed one leaves the owner's selection, which is what a checkout
    # trusts.
    def installation_repositories(payload)
      record = linked_installation(payload) or return
      return unless payload["action"].in?(%w[added removed])

      removed = payload["repositories_removed"].map { |repo| repo["id"].to_i }.to_set
      attributes = { repositories: record.repositories.reject { |repo| removed.include?(repo["id"].to_i) } }
      selection = payload.dig("installation", "repository_selection")
      attributes[:repository_selection] = selection if selection.present?
      record.update!(attributes)
    end

    # GitHub revoked the user's authorization of the App. The App's own user
    # tokens are never stored (see Api::GithubInstallationsController), so
    # this reaches a stored GithubConnection only when the OAuth connection
    # flow authorizes through this same App (github_client_id is the App's
    # client id). A connection made through a separate OAuth App is a grant
    # this revocation does not touch.
    def authorization(payload)
      return unless payload["action"] == "revoked"
      return if payload["sender_id"].blank?
      return unless ActionAgent.github_client_id.present? && ActionAgent.github_client_id == ActionAgent.github_app_client_id

      GithubConnection.where(github_user_id: payload["sender_id"].to_i).destroy_all
    end

    def linked_installation(payload)
      id = payload.dig("installation", "id")
      GithubInstallation.find_by(installation_id: id.to_i) if id.present?
    end

    def parse_time(value)
      Time.iso8601(value) if value.is_a?(String)
    rescue ArgumentError
      nil
    end
  end
end
