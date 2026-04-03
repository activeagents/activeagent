# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module ActiveAgent
  module Dashboard
    module Generators
      # Generator for installing the ActiveAgent Dashboard engine.
      #
      # Usage:
      #   rails generate active_agent:dashboard:install
      #
      # This will:
      # - Copy migration files for all dashboard models
      # - Create an initializer for configuration
      # - Add the engine mount to routes.rb
      # - Seed default agent templates
      #
      class InstallGenerator < Rails::Generators::Base
        include ActiveRecord::Generators::Migration

        source_root File.expand_path("templates", __dir__)

        class_option :multi_tenant, type: :boolean, default: false,
          desc: "Configure for multi-tenant mode with account association"

        class_option :skip_migrations, type: :boolean, default: false,
          desc: "Skip copying migration files"

        class_option :skip_routes, type: :boolean, default: false,
          desc: "Skip adding route mount"

        def copy_migrations
          return if options[:skip_migrations]

          migration_template "migrations/create_active_agent_agents.rb",
            "db/migrate/create_active_agent_agents.rb"

          migration_template "migrations/create_active_agent_agent_versions.rb",
            "db/migrate/create_active_agent_agent_versions.rb"

          migration_template "migrations/create_active_agent_agent_runs.rb",
            "db/migrate/create_active_agent_agent_runs.rb"

          migration_template "migrations/create_active_agent_agent_templates.rb",
            "db/migrate/create_active_agent_agent_templates.rb"

          migration_template "migrations/create_active_agent_sandbox_sessions.rb",
            "db/migrate/create_active_agent_sandbox_sessions.rb"

          migration_template "migrations/create_active_agent_sandbox_runs.rb",
            "db/migrate/create_active_agent_sandbox_runs.rb"

          migration_template "migrations/create_active_agent_session_recordings.rb",
            "db/migrate/create_active_agent_session_recordings.rb"

          migration_template "migrations/create_active_agent_telemetry_traces.rb",
            "db/migrate/create_active_agent_telemetry_traces.rb"
        end

        def create_initializer
          template "initializer.rb", "config/initializers/active_agent_dashboard.rb"
        end

        def mount_engine
          return if options[:skip_routes]

          route 'mount ActiveAgent::Dashboard::Engine => "/active_agent"'
        end

        def show_post_install
          say ""
          say "ActiveAgent Dashboard installed!", :green
          say ""
          say "Next steps:"
          say "  1. Run migrations: rails db:migrate"
          say "  2. Seed templates:  rails active_agent:dashboard:seed"
          say "  3. Configure authentication in config/initializers/active_agent_dashboard.rb"
          say "  4. Visit /active_agent to access the dashboard"
          say ""
        end

        private

        def migration_version
          "[#{ActiveRecord::Migration.current_version}]"
        end

        def multi_tenant?
          options[:multi_tenant]
        end
      end
    end
  end
end
