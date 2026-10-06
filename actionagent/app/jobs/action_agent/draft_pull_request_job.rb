# frozen_string_literal: true

module ActionAgent
  # Runs one queued publish of a DraftPullRequest through
  # DraftPullRequestPublisher, after asking ActionAgent.permission_checker
  # again whether the user who asked for it may publish pull requests. A
  # project's install pull request is published with the files the project
  # generates (ProjectInstallPullRequest).
  #
  # Takes the record's id and nothing else: the token is minted while the
  # job runs, and never passes through the queue. Not retried, since a
  # publish writes to GitHub.
  class DraftPullRequestJob < ApplicationJob
    queue_as :sandboxes

    def perform(draft_pull_request_id)
      # Claimed atomically, so a second job for the same record finds it no
      # longer queued.
      claimed = DraftPullRequest.where(id: draft_pull_request_id, status: "queued")
        .update_all(status: "publishing", updated_at: Time.current)
      return unless claimed == 1

      record = DraftPullRequest.find(draft_pull_request_id)
      user = record.publisher
      if ActionAgent.permitted?(user, :publish_pull_request, record)
        ProjectInstallPullRequest.publisher_for(record, user: user).publish!(record)
      else
        record.update!(status: "failed", error_code: "forbidden", error_message: "You do not have permission to publish pull requests")
      end
      broadcast(record)
    rescue StandardError => e
      Rails.logger.error("[ActionAgent] publishing draft pull request #{draft_pull_request_id} failed: #{e.class}: #{e.message}")
      DraftPullRequest.where(id: draft_pull_request_id, status: %w[queued publishing])
        .update_all(status: "failed", error_code: "github_error", error_message: "The publish failed unexpectedly", updated_at: Time.current)
    end

    private

    def broadcast(record)
      LiveUpdates.broadcast("sandbox_#{record.sandbox_session.session_id}", type: "pull_request", id: record.id, status: record.status)
    end
  end
end
