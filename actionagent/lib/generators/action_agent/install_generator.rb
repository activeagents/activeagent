# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module ActionAgent
  # Generator for installing the ActiveAgent Dashboard.
  #
  # @example Run the generator
  #   rails generate action_agent:install
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
      desc: "Skip copying the migrations"

    class_option :traces_only, type: :boolean, default: false,
      desc: "Install trace ingestion alone, without the agent/run/evaluation tables"

    class_option :skip_routes, type: :boolean, default: false,
      desc: "Skip adding the engine mount to routes.rb"

    def copy_migrations
      return if options[:skip_migrations]

      # An app that installed the dashboard when it shipped inside activeagent
      # already has this migration. Re-emitting it aborts the whole generator
      # on a duplicate name, so upgrade that install in place instead: the
      # table exists but predates agent attribution, and only agent_id is
      # missing.
      if existing_migration?("create_active_agent_telemetry_traces")
        say_status :skip, "create_active_agent_telemetry_traces already exists", :yellow

        unless existing_migration?("add_agent_id_to_active_agent_telemetry_traces")
          migration_template(
            "add_agent_id_to_active_agent_telemetry_traces.rb.erb",
            "db/migrate/add_agent_id_to_active_agent_telemetry_traces.rb"
          )
        end
      else
        migration_template(
          "create_active_agent_telemetry_traces.rb.erb",
          "db/migrate/create_active_agent_telemetry_traces.rb"
        )
      end

      # The rest of the dashboard — agents, runs, versions, conversations,
      # evaluations, sandboxes, recordings, keys. Skippable for an app that
      # only wants to be a trace sink.
      return if options[:traces_only]

      if existing_migration?("create_active_agent_dashboard_tables")
        say_status :skip, "create_active_agent_dashboard_tables already exists", :yellow
        return
      end

      migration_template(
        "create_active_agent_dashboard_tables.rb.erb",
        "db/migrate/create_active_agent_dashboard_tables.rb"
      )
    end

    def add_route
      return if options[:skip_routes]

      # Rails' `route` action is only idempotent on an exact string match,
      # so an app installed before the default path changed would get a
      # second mount — and two unnamed mounts of the same engine raise
      # "Invalid route name, already in use: 'active_agent'" at boot.
      routes_file = File.join(destination_root, "config/routes.rb")
      if File.exist?(routes_file) && File.read(routes_file).include?("ActionAgent::Engine")
        say_status :skip, "engine already mounted in config/routes.rb", :yellow
        return
      end

      route 'mount ActionAgent::Engine => "/activeagents"'
    end

    def create_initializer
      template(
        "action_agent.rb.erb",
        "config/initializers/action_agent.rb"
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
      unless options[:traces_only]
        say "\n"
        say "The dashboard stores API keys and provider credentials encrypted."
        say "Run `rails db:encryption:init` and add the keys to your credentials"
        say "before creating any."
      end
      say "\n"
    end

    private

    def migration_version
      "[#{ActiveRecord::Migration.current_version}]"
    end

    # Whether db/migrate already carries a migration with this name. Checked
    # against the filesystem rather than the database so the generator still
    # works before the database exists.
    def existing_migration?(name)
      Dir.glob(File.join(destination_root.to_s, "db", "migrate", "*_#{name}.rb")).any?
    end

    # Consumed by the migration template.
    def multi_tenant?
      options[:multi_tenant]
    end
  end
end
