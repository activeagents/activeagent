# frozen_string_literal: true

require "rails/generators/erb"

module Erb # :nodoc:
  module Generators # :nodoc:
    class AgentGenerator < Base # :nodoc:
      source_root File.expand_path("templates", __dir__)
      argument :actions, type: :array, default: [], banner: "method method"
      class_option :format, type: :string, default: "markdown", desc: "Specify format for templates (text or markdown)"
      class_option :json_schema, type: :boolean, default: false, desc: "Generate JSON schema files for actions"
      class_option :json_object, type: :boolean, default: false, desc: "Generate actions with JSON object response format"

      def initialize(*args, **kwargs)
        super(*args, **kwargs)

        # We must duplicate due to immutable hash
        dup_options = options.dup
        @options = dup_options.merge(template_engine: :erb)
      end

      def copy_view_files
        view_base_path = File.join("app/views/agents", class_path, file_name)
        empty_directory view_base_path

        # Create instructions file with the specified format
        file_extension = format == "markdown" ? "md" : format
        instructions_file = "instructions.#{file_extension}.erb"
        instructions_path = File.join(view_base_path, instructions_file)
        template "instructions.#{file_extension}.erb.tt", instructions_path

        # Create action view files
        actions.each do |action|
          @action = action

          # Create message file in specified format
          action_file = "#{action}.#{file_extension}.erb"
          action_path = File.join(view_base_path, action_file)
          template "message.#{file_extension}.erb.tt", action_path

          # Create schema file if requested
          if json_schema?
            schema_file = "#{action}.schema.json"
            schema_path = File.join(view_base_path, schema_file)
            template "schema.json.tt", schema_path
          end
        end
      end

      private
      def format
        options[:format]
      end

      def json_schema?
        options[:json_schema]
      end

      def json_object?
        options[:json_object]
      end

      def file_name
        @_file_name ||= super.sub(/_agent\z/i, "")
      end
    end
  end
end
