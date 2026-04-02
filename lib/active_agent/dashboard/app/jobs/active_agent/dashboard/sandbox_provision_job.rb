# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Background job for provisioning sandbox environments.
    #
    # Creates isolated execution environments (Docker, Cloud Run, etc.)
    # for running agents with tools.
    #
    class SandboxProvisionJob < ApplicationJob
      queue_as :default

      def perform(sandbox_session_id)
        session = SandboxSession.find(sandbox_session_id)
        return unless session.provisioning?

        begin
          result = provision_sandbox(session)

          session.mark_ready!(
            sandbox_url: result[:url],
            sandbox_job_id: result[:job_id]
          )
        rescue => e
          session.update!(
            status: :failed,
            error_message: e.message
          )
        end
      end

      private

      def provision_sandbox(session)
        case ActiveAgent::Dashboard.sandbox_service
        when :cloud_run
          provision_cloud_run(session)
        when :kubernetes
          provision_kubernetes(session)
        else
          provision_local(session)
        end
      end

      def provision_local(session)
        # Local mode: No actual provisioning needed
        # The sandbox runs in the same process or via Docker
        {
          url: "http://localhost:#{3000 + session.id}",
          job_id: "local-#{session.session_id}"
        }
      end

      def provision_cloud_run(session)
        # TODO: Implement Cloud Run provisioning
        raise NotImplementedError, "Cloud Run provisioning not yet implemented in engine"
      end

      def provision_kubernetes(session)
        # TODO: Implement Kubernetes provisioning
        raise NotImplementedError, "Kubernetes provisioning not yet implemented in engine"
      end
    end
  end
end
