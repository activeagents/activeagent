# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # The framework's telemetry configuration, now provided by the
    # activeagents-telemetry gem. This subclass keeps the framework's
    # historical behavior on top of the shared core:
    #
    # * telemetry is opt-in (`enabled` defaults to false)
    # * `local_storage: true` persists traces through the dashboard's trace
    #   model instead of HTTP
    #
    # Every other option — endpoint, api_key, sample_rate, batch_size,
    # flush_interval, capture_bodies, redact_attributes, service_name,
    # environment, resource_attributes — lives on the shared class, so
    # existing config/active_agent.yml files keep working unchanged.
    #
    # @see ActiveAgents::Telemetry::Configuration
    class Configuration < ActiveAgents::Telemetry::Configuration
      # Fallback ingest path when the dashboard engine's mount point can't
      # be resolved from the host's routes (e.g. engine not mounted).
      LOCAL_ENDPOINT_PATH = "/activeagents/api/traces"

      # @return [Boolean] Whether to store traces in the app's own database
      attr_reader :local_storage

      def initialize
        super
        # The framework predates the shared gem and has always been opt-in;
        # adapters treat the presence of an api_key as the switch instead.
        self.enabled = false
        @local_storage = false
      end

      def local_storage=(value)
        @local_storage = value == true
      end

      def local_storage?
        @local_storage
      end

      def local_store?
        local_storage? || super
      end

      # When local storage is on, traces persist through the dashboard's
      # trace model rather than leaving the process.
      def local_store
        super || (dashboard_store if local_storage?)
      end

      # Returns the resolved endpoint for trace reporting.
      def resolved_endpoint
        local_storage? ? local_endpoint_path : endpoint
      end

      # The dashboard engine's ingest path, derived from wherever the host
      # app actually mounted it — "/activeagents", "/observability", or "/"
      # on a dedicated subdomain all work. Falls back to
      # LOCAL_ENDPOINT_PATH when the engine isn't mounted.
      def local_endpoint_path
        mount = dashboard_mount_path
        mount ? "#{mount}/api/traces" : LOCAL_ENDPOINT_PATH
      end

      # The framework's historical fallback is "activeagent", not the shared
      # core's generic "ruby".
      def resolved_service_name
        value = super
        value == "ruby" ? "activeagent" : value
      end

      def to_h
        super.merge(local_storage: local_storage)
      end

      private

      # Persists a trace through the dashboard's trace model, honoring
      # ActionAgent.trace_model_class overrides. Idempotent on trace_id, as
      # HTTP ingest is.
      #
      # The dashboard is the `actionagent` gem, which the framework does not
      # depend on — every reference to it here is guarded, so local_storage
      # simply reports that it has nowhere to write when it isn't installed.
      def dashboard_store
        @dashboard_store ||= lambda do |trace, sdk|
          model = local_trace_model
          unless model
            resolved_logger.error(
              "[ActiveAgent::Telemetry] local_storage is enabled but no trace model is available — " \
              "add the actionagent gem and run `rails generate action_agent:install` first"
            )
            next
          end

          next if model.exists?(trace_id: trace["trace_id"])

          model.create_from_payload(trace, sdk)
        end
      end

      def local_trace_model
        if defined?(::ActionAgent) && ::ActionAgent.respond_to?(:trace_model)
          ::ActionAgent.trace_model
        elsif defined?(::ActionAgent::TelemetryTrace)
          ::ActionAgent::TelemetryTrace
        end
      rescue NameError
        nil
      end

      # The engine's mount point in the host app, found by locating the
      # mounted engine in the host's route set. Works regardless of the
      # helper name, so `mount ... => "/", as: :something_else` and
      # constraint-wrapped mounts resolve correctly. Returns nil when the
      # engine isn't mounted or no Rails app is booted; "" for a root mount.
      def dashboard_mount_path
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

        mount_path_in(::Rails.application.routes)
      rescue StandardError
        nil
      end

      # The engine's mount path within a given route set, or nil when it
      # isn't mounted there. Separate from #dashboard_mount_path so it can be
      # exercised against a route set directly.
      public def mount_path_in(route_set)
        return nil unless defined?(::ActionAgent::Engine)

        route = route_set.routes.find do |candidate|
          mounted_engine(candidate.app) == ::ActionAgent::Engine
        end
        return nil unless route

        # "/activeagents(.:format)" -> "/activeagents"; a root mount -> "".
        route.path.spec.to_s.sub(/\(\.:format\)\z/, "").chomp("/")
      end

      # Unwraps the constraint layers Rails wraps a mounted engine in,
      # returning the engine class (or nil for ordinary routes). Stops at the
      # engine class itself — engines also respond to #app (their route set),
      # so unwrapping blindly walks straight past them.
      def mounted_engine(app)
        5.times do
          return app if app.is_a?(Class) && app < ::Rails::Engine
          break unless app.respond_to?(:app) && !app.app.equal?(app)

          app = app.app
        end
        nil
      end
    end
  end
end
