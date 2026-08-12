# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # In-memory sandbox backend. Ships with the engine so the sandbox surface
    # is exercisable in development and tests without any container runtime;
    # backends that talk to real infrastructure are registered by the host app
    # (see ActiveAgent::Dashboard.sandbox_backends).
    class MockSandboxBackend
      def initialize
        @sandboxes = {}
      end

      def create_sandbox(session, instance_tier: nil)
        tier = instance_tier || SandboxInstanceTier.free_tier
        name = "mock-sandbox-#{SecureRandom.hex(4)}"

        @sandboxes[name] = {
          container_name: name,
          container_ip: "127.0.0.1",
          url: "http://127.0.0.1:8080",
          session_id: session.session_id,
          status: "running",
          instance_tier: tier.id,
          resources: {
            cpu_cores: tier.cpu_cores,
            memory_gb: tier.memory_gb,
            gpu: tier.gpu
          },
          hourly_cost: tier.hourly_cost.to_f,
          created_at: Time.current
        }
        @sandboxes[name]
      end

      def status(sandbox_id)
        @sandboxes[sandbox_id] || { status: "not_found" }
      end

      def terminate(sandbox_id)
        @sandboxes.delete(sandbox_id)
        true
      end

      def list_sandboxes
        @sandboxes.values
      end

      def cleanup_expired
        0
      end
    end
  end
end
