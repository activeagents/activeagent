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

      private

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
