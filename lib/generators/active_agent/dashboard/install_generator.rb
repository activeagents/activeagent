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

      class_option :multi_tenant, type: :boolean, default: false,
        desc: "Scope traces to an Account (adds account_id to the migration)"

      class_option :skip_migrations, type: :boolean, default: false,
        desc: "Skip copying the telemetry traces migration"

      class_option :skip_routes, type: :boolean, default: false,
        desc: "Skip adding the engine mount to routes.rb"

      def copy_migrations
        return if options[:skip_migrations]

        migration_template(
          "create_active_agent_telemetry_traces.rb.erb",
          "db/migrate/create_active_agent_telemetry_traces.rb"
        )
      end

      def add_route
        return if options[:skip_routes]

        # Rails' `route` action is only idempotent on an exact string match,
        # so an app installed before the default path changed would get a
        # second mount — and two unnamed mounts of the same engine raise
        # "Invalid route name, already in use: 'active_agent'" at boot.
        routes_file = File.join(destination_root, "config/routes.rb")
        if File.exist?(routes_file) && File.read(routes_file).include?("ActiveAgent::Dashboard::Engine")
          say_status :skip, "engine already mounted in config/routes.rb", :yellow
          return
        end

        route 'mount ActiveAgent::Dashboard::Engine => "/activeagents"'
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
        say "  3. Visit /activeagents to view the dashboard"
        say "\n"
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end

      # Consumed by the migration template.
      def multi_tenant?
        options[:multi_tenant]
      end
    end
  end
end
