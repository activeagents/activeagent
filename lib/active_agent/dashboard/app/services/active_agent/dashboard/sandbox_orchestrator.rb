# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # SandboxOrchestrator
    #
    # Unified interface for managing agent sandbox sessions.
    # Supports multiple backends for cloud-agnostic deployment:
    #
    #   - incus:     Self-hosted Incus containers (any Linux host)
    #   - cloud_run: Google Cloud Run Jobs (serverless)
    #   - kubernetes: Kubernetes pods (GKE, EKS, self-hosted k8s)
    #
    # Configuration:
    #   Set SANDBOX_BACKEND environment variable to choose backend.
    #   Default: "incus" for simplicity
    #
    # Usage:
    #   orchestrator = SandboxOrchestrator.new
    #   result = orchestrator.create_sandbox(session)
    #   status = orchestrator.status(container_id)
    #   orchestrator.terminate(container_id)
    #
    class SandboxOrchestrator
      # The engine ships only the in-memory backend. Anything that talks to
      # real infrastructure (Incus, Kubernetes, Cloud Run) is registered by
      # the app that operates it, so the engine carries none of those SDKs:
      #
      #   ActiveAgent::Dashboard.sandbox_backends = {
      #     "cloud_run" => "CloudRunService"
      #   }
      BUILT_IN_BACKENDS = { "mock" => "ActiveAgent::Dashboard::MockSandboxBackend" }.freeze

      # Backends disagree on what to call each verb. Candidates are tried in
      # order and the first the backend responds to wins, so a host-registered
      # class needs no adapter of its own.
      ADAPTER_METHODS = {
        create: %i[create_sandbox create_sandbox_pod create_sandbox_job],
        status: %i[status container_status pod_status job_status],
        terminate: %i[terminate terminate_pod cancel_job],
        list: %i[list_sandboxes list_sandbox_pods list_jobs],
        cleanup: %i[cleanup_expired cleanup_expired_pods cleanup_expired_jobs]
      }.freeze

      class UnsupportedBackendError < StandardError; end

      # All backend names available in this install.
      def self.backends
        BUILT_IN_BACKENDS.merge(ActiveAgent::Dashboard.sandbox_backends.to_h.transform_keys(&:to_s))
      end

      # The backend used when none is named: whatever the host app configured
      # as sandbox_service, falling back to the in-memory one.
      def self.default_backend
        name = ENV["SANDBOX_BACKEND"].presence || ActiveAgent::Dashboard.sandbox_service.to_s
        backends.key?(name) ? name : "mock"
      end

      def initialize(backend: nil)
        @backend_name = (backend || self.class.default_backend).to_s
        class_name = self.class.backends[@backend_name]
        raise UnsupportedBackendError, "Unknown backend: #{@backend_name}" if class_name.nil?

        @backend = class_name.constantize.new
      end

      attr_reader :backend_name

      # Create a new sandbox for the given session
      #
      # @param sandbox_session [SandboxSession] The session to create a sandbox for
      # @param instance_tier [String, Symbol, SandboxInstanceTier] Optional instance tier
      # @return [Hash] Sandbox details including ID/name and URL
      def create_sandbox(sandbox_session, instance_tier: nil)
        # Resolve tier
        tier = resolve_tier(instance_tier)

        method = adapter_method(:create)
        result = if accepts_instance_tier?(method)
          @backend.public_send(method, sandbox_session, instance_tier: tier)
        else
          @backend.public_send(method, sandbox_session)
        end

        # Normalize response format across backends
        {
          sandbox_id: result[:container_name] || result[:pod_name] || result[:job_name],
          url: result[:url],
          ip: result[:container_ip] || result[:pod_ip],
          backend: @backend_name,
          instance_tier: result[:instance_tier] || tier&.id,
          resources: result[:resources],
          hourly_cost: result[:hourly_cost] || tier&.hourly_cost&.to_f,
          created_at: result[:created_at] || Time.current
        }
      end

      # List available instance tiers
      #
      # @param category [String, nil] Optional category filter (free, pro, enterprise)
      # @return [Array<SandboxInstanceTier>] Available tiers
      def available_tiers(category: nil)
        tiers = SandboxInstanceTier.available
        tiers = tiers.select { |t| t.category == category.to_s } if category
        tiers
      end

      # Get a specific instance tier
      #
      # @param tier_id [String, Symbol] Tier ID
      # @return [SandboxInstanceTier]
      def get_tier(tier_id)
        SandboxInstanceTier.find(tier_id)
      end

      # Get the status of a sandbox
      #
      # @param sandbox_id [String] The sandbox ID (container name, pod name, etc.)
      # @return [Hash] Sandbox status
      def status(sandbox_id)
        @backend.public_send(adapter_method(:status), sandbox_id)
      end

      # Terminate a sandbox
      #
      # @param sandbox_id [String] The sandbox ID to terminate
      # @return [Boolean] true if terminated
      def terminate(sandbox_id)
        @backend.public_send(adapter_method(:terminate), sandbox_id)
      end

      # List all active sandboxes
      #
      # @return [Array<Hash>] List of sandbox statuses
      def list_sandboxes
        @backend.public_send(adapter_method(:list))
      end

      # Cleanup expired sandboxes
      #
      # @return [Integer] Number of sandboxes cleaned up
      def cleanup_expired
        @backend.public_send(adapter_method(:cleanup))
      end

      # Check if the backend is healthy
      #
      # @return [Boolean] true if backend is reachable
      def healthy?
        # A backend that can list is reachable; one that cannot is assumed
        # healthy because there is nothing to probe.
        list_sandboxes if ADAPTER_METHODS[:list].any? { |m| @backend.respond_to?(m) }
        true
      rescue => e
        Rails.logger.error("Sandbox backend health check failed: #{e.message}")
        false
      end

      # Get backend-specific configuration info
      #
      # @return [Hash] Backend configuration
      def backend_info
        {
          name: @backend_name,
          class: @backend.class.name,
          healthy: healthy?,
          features: backend_features
        }
      end

      private

      # The backend's method for +verb+, or a clear error naming what it
      # would have to implement.
      def adapter_method(verb)
        ADAPTER_METHODS.fetch(verb).find { |m| @backend.respond_to?(m) } ||
          raise(UnsupportedBackendError,
            "#{@backend.class} implements none of #{ADAPTER_METHODS.fetch(verb).join(', ')}")
      end

      def accepts_instance_tier?(method)
        @backend.method(method).parameters.any? { |_type, name| name == :instance_tier }
      end

      def resolve_tier(tier_param)
        return nil unless tier_param

        if tier_param.is_a?(SandboxInstanceTier)
          tier_param
        else
          SandboxInstanceTier.find(tier_param)
        end
      rescue ArgumentError
        Rails.logger.warn("Unknown instance tier: #{tier_param}, using default")
        SandboxInstanceTier.default_tier
      end

      def backend_features
        # A host-registered backend can describe itself; otherwise fall back
        # to what the engine knows about the backends it has seen.
        return @backend.features if @backend.respond_to?(:features)

        case @backend_name
        when "incus"
          {
            cloud_agnostic: true,
            isolation: "namespaces + apparmor",
            networking: "bridge",
            persistent_storage: true,
            live_migration: true,
            self_hosted: true
          }
        when "kubernetes"
          {
            cloud_agnostic: true,
            isolation: "pods + gvisor",
            networking: "cni + network_policies",
            persistent_storage: true,
            live_migration: false,
            self_hosted: true
          }
        when "cloud_run"
          {
            cloud_agnostic: false,
            isolation: "gvisor",
            networking: "vpc_connector",
            persistent_storage: false,
            live_migration: false,
            self_hosted: false
          }
        when "mock"
          {
            cloud_agnostic: true,
            isolation: "none",
            networking: "mock",
            persistent_storage: false,
            live_migration: false,
            self_hosted: true
          }
        end
      end
    end
  end
end
