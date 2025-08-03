# frozen_string_literal: true

require "rails/generators/erb"
require "active_agent"

module Erb # :nodoc:
  module Generators # :nodoc:
    class AgentGenerator < Base # :nodoc:
      source_root File.expand_path("templates", __dir__)
      argument :actions, type: :array, default: [], banner: "method method"
      class_option :formats, type: :array, default: [ "text" ], desc: "Specify formats to generate (text, html, json)"

      def copy_view_files
        agent_views_dir = agent_views_directory
        view_base_path = File.join(agent_views_dir, class_path, file_name + "_agent")
        empty_directory view_base_path

        if behavior == :invoke
          formats.each do |format|
            layout_path = File.join("app/views/layouts", class_path, filename_with_extensions("agent", format))
            template filename_with_extensions(:layout, format), layout_path unless File.exist?(layout_path)
          end
        end

        actions.each do |action|
          @action = action

          formats.each do |format|
            @path = File.join(view_base_path, filename_with_extensions(action, format))
            template filename_with_extensions(:view, format), @path
          end
        end
      end

      private
      def formats
        options[:formats].map(&:to_sym)
      end

      def file_name
        @_file_name ||= super.sub(/_agent\z/i, "")
      end

      def agent_views_directory
        # Ensure config is loaded
        ActiveAgent.load_configuration(Rails.root.join("config", "active_agent.yml")) unless ActiveAgent.config

        ActiveAgent.config["agent_views_directory"]
      end
    end
  end
end
