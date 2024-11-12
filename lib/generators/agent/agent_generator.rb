# frozen_string_literal: true

module Rails
  module Generators
    class MailerGenerator < NamedBase
      source_root File.expand_path("templates", __dir__)

      argument :actions, type: :array, default: [], banner: "method method"

      check_class_collision suffix: "Mailer"

      def create_agent_file
        template "agent.rb", File.join("app/agents", class_path, "#{file_name}_agent.rb")

        in_root do
          if behavior == :invoke && !File.exist?(application_agent_file_name)
            template "application_agent.rb", application_agent_file_name
          end
        end
      end

      hook_for :template_engine, :test_framework

      private
        def file_name # :doc:
          @_file_name ||= super.sub(/_agent\z/i, "")
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
