# frozen_string_literal: true

module ActiveAgent
  module Generators
    class AgentGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      argument :actions, type: :array, default: [], banner: "method method"

      check_class_collision

      def create_agent_file
        template "agent.rb", File.join("app/agents", class_path, "#{file_name}.rb")

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
          
          # Use configured template engines or fall back to defaults
          json_template_engine = json_template_engine_for_views || "jbuilder"
          html_template_engine = html_template_engine_for_views || "erb"
          
          @schema_path = File.join("app/views", class_path, file_name, "#{action}.json.#{json_template_engine}")
          @view_path = File.join("app/views", class_path, file_name, "#{action}.html.#{html_template_engine}")
          
          template "action.json.#{json_template_engine}", @schema_path
          template "action.html.#{html_template_engine}", @view_path
        end
      end

      def create_layout_files
        # Create the application agent layouts
        template "layout.text.erb", "app/views/layouts/agent.text.erb"
        template "layout.html.erb", "app/views/layouts/agent.html.erb"
      end

      private

      def test_framework
        ::Rails.application.config.generators.options[:rails][:test_framework]
      end

      def template_engine
        ::Rails.application.config.generators.options[:rails][:template_engine]
      end

      def json_template_engine_for_views
        # Check if there's a specific JSON template engine configured
        json_engine = ::Rails.application.config.generators.options[:rails][:json_template_engine]
        json_engine || "jbuilder" # Default to jbuilder if not specified
      end
      
      def html_template_engine_for_views
        # Use the configured template engine or default to erb
        template_engine || "erb"
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
