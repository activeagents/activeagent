# frozen_string_literal: true

require "rails/generators/erb"

module Erb # :nodoc:
  module Generators # :nodoc:
    class AgentGenerator < Base # :nodoc:
      hook_for :template_engine, :test_framework