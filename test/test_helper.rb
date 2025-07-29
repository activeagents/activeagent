# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require "jbuilder"
require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
require "rails/test_help"
require "vcr"
require "minitest/mock"

def doc_example_output(example = nil)
  file_name = @NAME.dasherize

  file_path = Rails.root.join("..", "..", "docs", "parts", "examples", "#{file_name}-#{example.class.name.split("::").last.downcase}.md")
  puts "\nWriting example output to #{file_path}\n"
  FileUtils.mkdir_p(File.dirname(file_path))
  File.write(file_path, ActiveAgent.filter_credential_keys(example.inspect.to_s))
end

VCR.configure do |config|
  config.cassette_library_dir = "test/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.filter_sensitive_data("<OPENAI_API_KEY>") { Rails.application.credentials.dig(:openai, :api_key) }
  config.filter_sensitive_data("<OPEN_ROUTER_API_KEY>") { Rails.application.credentials.dig(:open_router, :api_key) }
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("test/fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("test/fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end
