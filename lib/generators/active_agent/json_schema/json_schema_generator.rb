require "rails/generators"

module ActiveAgent
  module Generators
    class JsonSchemaGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)
      argument :actions, type: :array, default: [], banner: "method method"

      check_class_collision suffix: "Agent"

      desc <<~DESC
        Generates stub *.json.jbuilder tool‑schema templates
        for the specified agent actions.

        Example:
          rails g active_agent:json_schema Report generate summarize

        This will create:

            app/views/report_agent/generate.json.jbuilder
            app/views/report_agent/summarize.json.jbuilder
      DESC

      def create_schema_templates
        view_base = File.join("app/views", class_path, file_name + "_agent")
        empty_directory view_base

        actions.each do |action|
          @action = action
          dest    = File.join(view_base, "#{action}.json.jbuilder")

          if behavior == :invoke && File.exist?(dest)
            say_status :skip, dest, :yellow
            next
          end

          @path   = dest.sub(%r{\Aapp/views/}, "")
          template "view.json.jbuilder.tt", dest
        end
      end

      private

      def file_name
        @_file_name ||= super.sub(/_agent\z/i, "")
      end
    end
  end
end
