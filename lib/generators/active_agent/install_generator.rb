# frozen_string_literal: true
module ActiveAgent
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      class_option :skip_config, type: :boolean, default: false, desc: "Skip configuration file generation"
      class_option :formats, type: :array, default: ['text'], desc: 'Specify formats to generate (text, html, json)'
      
      def self.usage_path
        @usage_path ||= File.expand_path("../USAGE", __dir__)
      end
      source_root File.expand_path("templates", __dir__)

      def create_configuration
        template "active_agent.yml", "config/active_agent.yml" unless options[:skip_config]
      end

      def create_application_agent
        in_root do
          if !File.exist?(application_agent_file_name)
            template "application_agent.rb", application_agent_file_name
          end
        end
      end

      hook_for :template_engine

      private
      def formats
        options[:formats].map(&:to_sym)
      end

      def application_agent_file_name
        "app/agents/application_agent.rb"
      end
    end
  end
end
