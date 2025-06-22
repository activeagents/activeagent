# frozen_string_literal: true

module ActiveAgent
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      hook_for :template_engine, :test_framework

      def create_configuration
        template "active_agent.yml", "config/active_agent.yml"
      end
    end
  end
end
