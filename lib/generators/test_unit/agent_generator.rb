# frozen_string_literal: true

require "rails/generators/test_unit"

module TestUnit # :nodoc:
  module Generators # :nodoc:
    class AgentGenerator < Base # :nodoc:
      source_root File.expand_path("templates", __dir__)
      argument :actions, type: :array, default: [], banner: "method method"

      def check_class_collision
        class_collisions "#{class_name}AgentTest", "#{class_name}AgentPreview"
      end

      def create_test_files
        template "functional_test.rb", File.join("test/agents", class_path, "#{file_name}_agent_test.rb")
      end

      def create_preview_files
        template "preview.rb", File.join("test/docs/previews", class_path, "#{file_name}_agent_preview.rb")
      end

      private

      def file_name
        @_file_name ||= super.sub(/_agent\z/i, "")
      end
    end
  end
end
