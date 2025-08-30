# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module SolidAgent
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Installs SolidAgent and creates database migrations"

      def create_initializer
        template "solid_agent.rb", "config/initializers/solid_agent.rb"
      end

      def create_migrations
        migration_template "create_solid_agent_tables.rb", 
                          "db/migrate/create_solid_agent_tables.rb",
                          migration_version: migration_version
      end

      def display_post_install_message
        say "\n🎉 SolidAgent has been installed!\n\n", :green
        say "Next steps:", :yellow
        say "  1. Run migrations: rails db:migrate"
        say "  2. Configure SolidAgent in config/initializers/solid_agent.rb"
        say "  3. Add 'include SolidAgent::Persistable' to your ApplicationAgent"
        say "\n"
        say "For more information, visit: https://github.com/activeagent/solid_agent", :cyan
      end

      private

      def migration_version
        "[#{ActiveRecord::Migration.current_version}]"
      end
    end
  end
end