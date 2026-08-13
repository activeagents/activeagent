# frozen_string_literal: true

module ActionAgent
  class SandboxCleanupJob < ApplicationJob
    queue_as :sandboxes

    # Clean up Cloud Run resources for an expired sandbox
    def perform(sandbox_session_id)
      sandbox = SandboxSession.find_by(id: sandbox_session_id)
      return unless sandbox

      Rails.logger.info("Cleaning up sandbox: #{sandbox.session_id}")

      # Delete Cloud Run Job if exists
      if sandbox.cloud_run_job_id.present? && !Rails.env.development?
        delete_cloud_run_job(sandbox.cloud_run_job_id)
      end

      # Optionally delete old sandbox records
      # For now, keep for analytics
      sandbox.update!(cloud_run_url: nil, cloud_run_job_id: nil)
    end

    # Periodic cleanup of all expired sandboxes
    def self.cleanup_expired!
      SandboxSession.expired_sessions.active.find_each do |sandbox|
        sandbox.expire!
      end
    end

    private

    def delete_cloud_run_job(job_id)
      require "google/cloud/run/v2"

      client = Google::Cloud::Run::V2::Jobs::Client.new
      client.delete_job(name: job_id)
    rescue => e
      Rails.logger.warn("Failed to delete Cloud Run job #{job_id}: #{e.message}")
    end
  end
end
