# frozen_string_literal: true

module ActiveAgent
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      def self.usage_path
        @usage_path ||= File.expand_path("../USAGE", __dir__)
      end
      source_root File.expand_path("templates", __dir__)

      hook_for :template_engine, :test_framework

      def create_configuration
        template "active_agent.yml", "config/active_agent.yml"
      end

      def create_application_agent
        in_root do
          if !File.exist?(application_agent_file_name)
            template "application_agent.rb", application_agent_file_name
          end
        end
      end

      private

      def application_agent_file_name
        "app/agents/application_agent.rb"
      end
    end
  end
end
