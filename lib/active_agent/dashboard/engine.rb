# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Rails Engine for the ActiveAgent Dashboard.
    #
    # Provides the free self-hosted dashboard: telemetry traces, metrics,
    # and the local trace ingestion API.
    #
    # Mount in your routes:
    #   mount ActiveAgent::Dashboard::Engine => "/active_agent"
    #
    class Engine < ::Rails::Engine
      # The engine lives at lib/active_agent/dashboard rather than the gem
      # root. Rails derives an engine's load paths (app/models,
      # app/controllers, app/jobs, app/views, config/routes.rb) from
      # find_root when +config+ is first materialized — which
      # isolate_namespace below triggers via +routes+ — so this override
      # must be defined before anything touches config. Overriding only
      # +root+ leaves the engine's classes off host applications' autoload
      # paths entirely.
      def self.find_root(_from)
        root
      end

      def self.root
        @root ||= Pathname.new(File.expand_path("..", __FILE__))
      end

      isolate_namespace ActiveAgent::Dashboard

      # Use a unique engine name to avoid conflicts
      engine_name "active_agent"

      # Alias for consistency with existing code
      def self.dashboard_root
        root
      end

      config.active_agent_dashboard = ActiveSupport::OrderedOptions.new
    end
  end
end
