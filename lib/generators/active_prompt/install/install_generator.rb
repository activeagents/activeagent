# frozen_string_literal: true
require "rails/generators"
module ActivePrompt
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../..", __dir__) # engine root

      desc "Copy ActivePrompt migrations into the host app"

      def copy_migrations
        rake("railties:install:migrations FROM=active_prompt")
      end

      def show_readme
        say_status :info, "Run `bin/rails db:migrate` to apply ActivePrompt tables.", :blue
      end
    end
  end
end
