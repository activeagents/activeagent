# frozen_string_literal: true

module ActiveAgent
  module Generators
    class AgentGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      argument :actions, type: :array, default: [], banner: "method method"

      check_class_collision suffix: "Agent"

      def create_agent_file
        template "agent.rb", File.join("app/agents", class_path, "#{file_name}_agent.rb")

        in_root do
          if behavior == :invoke && !File.exist?(application_agent_file_name)
            template "application_agent.rb", application_agent_file_name
          end
        end
      end

      def create_test_file
        if test_framework == :rspec
          template "agent_spec.rb", File.join("spec/agents", class_path, "#{file_name}_agent_spec.rb")
        else
          template "agent_test.rb", File.join("test/agents", class_path, "#{file_name}_agent_test.rb")
        end
      end

      def create_view_files
        actions.each do |action|
          @action = action
          @schema_path = File.join("app/views", class_path, file_name, "#{action}.json.jbuilder")
          @view_path = File.join("app/views", class_path, file_name, "#{action}.html.#{template_engine}")
          template "action.json.jbuilder", @schema_path
          template "action.html.#{template_engine}", @view_path
        end
      end

      private

      def test_framework
        ::Rails.application.config.generators.options[:rails][:test_framework]
      end

      def template_engine
        ::Rails.application.config.generators.options[:rails][:template_engine]
      end

      def file_name # :doc:
        @_file_name ||= super + "_agent"
      end

      def application_agent_file_name
        @_application_agent_file_name ||= if mountable_engine?
          "app/agents/#{namespaced_path}/application_agent.rb"
        else
          "app/agents/application_agent.rb"
        end
      end
    end
  end
end
