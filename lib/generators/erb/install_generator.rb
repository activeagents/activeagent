# frozen_string_literal: true

require "rails/generators"

module Erb # :nodoc:
  module Generators # :nodoc:
    class InstallGenerator < ::Rails::Generators::Base # :nodoc:
      source_root File.expand_path("templates", __dir__)

      def create_agent_layouts
        template "layout.html.erb.tt", "app/views/layouts/agent.html.erb"
        template "layout.text.erb.tt", "app/views/layouts/agent.text.erb"
        template "layout.json.erb.tt", "app/views/layouts/agent.json.erb"
      end
    end
  end
end
