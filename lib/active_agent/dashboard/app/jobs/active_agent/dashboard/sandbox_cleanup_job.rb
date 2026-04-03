# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Background job for cleaning up sandbox environments.
    #
    # Removes containers, Cloud Run jobs, or other resources
    # when a sandbox session expires.
    #
    class SandboxCleanupJob < ApplicationJob
      queue_as :default

      def perform(sandbox_session_id)
        session = SandboxSession.find_by(id: sandbox_session_id)
        return unless session

        cleanup_sandbox(session)
      end

      private

      def cleanup_sandbox(session)
        case ActiveAgent::Dashboard.sandbox_service
        when :cloud_run
          cleanup_cloud_run(session)
        when :kubernetes
          cleanup_kubernetes(session)
        else
          cleanup_local(session)
        end
      end

      def cleanup_local(session)
        # Local mode: Nothing to clean up
        Rails.logger.info "[ActiveAgent::Dashboard] Cleaned up local sandbox: #{session.session_id}"
      end

      def cleanup_cloud_run(session)
        # TODO: Implement Cloud Run cleanup
        Rails.logger.info "[ActiveAgent::Dashboard] Would clean up Cloud Run job: #{session.cloud_run_job_id}"
      end

      def cleanup_kubernetes(session)
        # TODO: Implement Kubernetes cleanup
        Rails.logger.info "[ActiveAgent::Dashboard] Would clean up Kubernetes pod: #{session.cloud_run_job_id}"
      end
    end
  end
end
