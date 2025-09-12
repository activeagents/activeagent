# frozen_string_literal: true

require "rails/generators/erb"

module Erb # :nodoc:
  module Generators # :nodoc:
    class AgentGenerator < Base # :nodoc:
      source_root File.expand_path("templates", __dir__)
      argument :actions, type: :array, default: [], banner: "method method"
      class_option :formats, type: :array, default: [ "text" ], desc: "Specify formats to generate (text, html, json)"

      def initialize(*args, **kwargs)
        super(*args, **kwargs)

        # We must duplicate due to immutable hash
        dup_options = options.dup
        @options = dup_options.merge(template_engine: :erb)
      end

      def copy_view_files
        view_base_path = File.join("app/views", class_path, file_name + "_agent")
        empty_directory view_base_path

        if behavior == :invoke
          formats.each do |format|
            layout_path = File.join("app/views/layouts", class_path, filename_with_extensions("agent", format))
            template filename_with_extensions(:layout, format), layout_path unless File.exist?(layout_path)
          end
        end

        instructions_path = File.join(view_base_path, "instructions.text.erb")
        template "instructions.text.erb.tt", instructions_path

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
    end
  end
end
