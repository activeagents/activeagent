# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module ActiveAgent
  module Dashboard
    # Generator for installing the ActiveAgent Dashboard.
    #
    # @example Run the generator
    #   rails generate active_agent:dashboard:install
    #
    # This will:
    # - Create the telemetry_traces table migration
    # - Add mount directive to routes
    # - Create initializer for dashboard configuration
    #
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Installs the ActiveAgent Dashboard with telemetry storage"

      def create_migration
        migration_template(
          "create_active_agent_telemetry_traces.rb.erb",
          "db/migrate/create_active_agent_telemetry_traces.rb"
        )
      end

      def add_route
        route 'mount ActiveAgent::Dashboard::Engine => "/active_agent"'
      end

      def create_initializer
        template(
          "active_agent_dashboard.rb.erb",
          "config/initializers/active_agent_dashboard.rb"
        )
      end

      def show_readme
        say "\n"
        say "ActiveAgent Dashboard installed successfully!", :green
        say "\n"
        say "Next steps:"
        say "  1. Run migrations: rails db:migrate"
        say "  2. Configure telemetry in config/active_agent.yml:"
        say "     telemetry:"
        say "       enabled: true"
        say "       local_storage: true"
        say "  3. Visit /active_agent to view the dashboard"
        say "\n"
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end
