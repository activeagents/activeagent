# test/test_helper.rb

require "minitest/autorun"
require "mocha/minitest"
require "active_support/test_case"
require "active_support/testing/autorun"

# Add the lib directory to the load path
$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)

# Require the main ActiveAgent file (adjust the path as needed)
require "active_agent"

# Set up any test configurations or helper methods here
class ActiveSupport::TestCase
  # Add any setup methods or configurations needed for all tests
end
