# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Rails Engine for the ActiveAgent Dashboard.
    #
    # Provides a full-featured dashboard for managing agents, viewing telemetry,
    # running sandboxes, and recording sessions.
    #
    # Mount in your routes:
    #   mount ActiveAgent::Dashboard::Engine => "/active_agent"
    #
    class Engine < ::Rails::Engine
      isolate_namespace ActiveAgent::Dashboard

      # Use a unique engine name to avoid conflicts
      engine_name "active_agent"

      # Override engine root to point to the dashboard directory
      # This must be set before paths are computed
      def self.root
        @root ||= Pathname.new(File.expand_path("..", __FILE__))
      end

      # Alias for consistency with existing code
      def self.dashboard_root
        root
      end

      config.active_agent_dashboard = ActiveSupport::OrderedOptions.new

      initializer "active_agent.dashboard.append_view_paths" do
        ActiveSupport.on_load(:action_controller) do
          prepend_view_path ActiveAgent::Dashboard::Engine.root.join("app", "views").to_s
        end
      end
    end
  end
end
