# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Rails Engine for the ActiveAgent telemetry dashboard.
    #
    # Mount in your routes:
    #   mount ActiveAgent::Dashboard::Engine => "/active_agent"
    #
    class Engine < ::Rails::Engine
      isolate_namespace ActiveAgent::Dashboard

      # Use a unique engine name to avoid conflicts
      engine_name "active_agent_dashboard"

      # Engine root for locating assets
      def self.dashboard_root
        @dashboard_root ||= Pathname.new(File.expand_path("..", __FILE__))
      end

      # Draw the engine routes
      def self.draw_routes
        routes.draw do
          root to: "traces#index"

          resources :traces, only: [:index, :show] do
            collection do
              get :metrics
            end
          end

          namespace :api do
            resources :traces, only: [:create]
          end
        end
      end

      # Require engine controllers, models, and jobs
      def self.load_engine_files
        dashboard_root = self.dashboard_root

        # Load models
        require dashboard_root.join("app", "models", "active_agent", "telemetry_trace").to_s

        # Load jobs
        require dashboard_root.join("app", "jobs", "active_agent", "process_telemetry_traces_job").to_s

        # Load controllers
        require dashboard_root.join("app", "controllers", "active_agent", "dashboard", "application_controller").to_s
        require dashboard_root.join("app", "controllers", "active_agent", "dashboard", "traces_controller").to_s
        require dashboard_root.join("app", "controllers", "active_agent", "dashboard", "api", "traces_controller").to_s
      end

      config.active_agent_dashboard = ActiveSupport::OrderedOptions.new

      initializer "active_agent.dashboard.append_view_paths" do |app|
        dashboard_root = ActiveAgent::Dashboard::Engine.dashboard_root
        ActionController::Base.prepend_view_path(dashboard_root.join("app", "views").to_s)
      end

      # Use to_prepare to load files before each request in development
      # and once in production
      config.to_prepare do
        ActiveAgent::Dashboard::Engine.load_engine_files
      end
    end

    # Draw routes when the engine is loaded
    Engine.draw_routes
  end
end
