# frozen_string_literal: true

module Erb # :nodoc:
  module Generators # :nodoc:
    class InstallGenerator < ::Rails::Generators::Base # :nodoc:
      source_root File.expand_path("templates", __dir__)
      class_option :formats, type: :array, default: [ "text" ], desc: "Specify formats to generate (text, html, json)"

      def create_agent_layouts
        if behavior == :invoke
          formats.each do |format|
            layout_path = File.join("app/views/layouts", filename_with_extensions("agent", format))
            template filename_with_extensions(:layout, format), layout_path unless File.exist?(layout_path)
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

      def filename_with_extensions(name, file_format = format)
        [ name, file_format, handler ].compact.join(".")
      end

      def handler
        :erb
      end
    end
  end
end
