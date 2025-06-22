# frozen_string_literal: true

require "rails/generators/test_unit"

module TestUnit # :nodoc:
  module Generators # :nodoc:
    class InstallGenerator < Base # :nodoc:
      # TestUnit install generator for ActiveAgent
      # This can be used to create additional test-specific files during installation
      # Currently no additional files are needed for TestUnit setup
    end
  end
end
