# frozen_string_literal: true

require "active_support/test_case"

module ActiveAgent
  class TestCase < ActiveSupport::TestCase
    # minimal base to satisfy Zeitwerk
  end
end

# Back-compat for any existing tests
ActiveAgentTestCase = ActiveAgent::TestCase unless defined?(ActiveAgentTestCase)
