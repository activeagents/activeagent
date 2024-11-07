# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [File.expand_path("../test/dummy/db/migrate", __dir__)]
require "rails/test_help"
require "minitest/autorun"
require "mocha/minitest"
require "active_agent/test_case"
require "active_support/testing/autorun"

# Add the lib directory to the load path
$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)

# Require the main ActiveAgent file (adjust the path as needed)
require "active_agent"

if ActiveAgent::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [File.expand_path("fixtures", __dir__)]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end
