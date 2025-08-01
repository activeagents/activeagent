# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require "jbuilder"
require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
require "rails/test_help"
require "vcr"
require "minitest/mock"

def doc_example_output(example = nil, test_name = nil)
  # Extract caller information
  caller_info = caller.find { |line| line.include?("_test.rb") }
  file_name = @NAME.dasherize
  test_name ||= name.to_s.dasherize if respond_to?(:name)
  
  # Extract file path and line number from caller
  if caller_info =~ /(.+):(\d+):in/
    test_file = $1.split("/").last
    line_number = $2
  end

  file_path = Rails.root.join("..", "..", "docs", "parts", "examples", "#{file_name}-#{test_name}.md")
  puts "\nWriting example output to #{file_path}\n"
  FileUtils.mkdir_p(File.dirname(file_path))
  
  # Format the output with metadata
  content = []
  content << "<!-- Generated from #{test_file}:#{line_number} -->"
  content << "<!-- Test: #{test_name} -->"
  content << ""
  
  # Determine if example is JSON
  if example.is_a?(Hash) || example.is_a?(Array)
    content << "```json"
    content << JSON.pretty_generate(example)
    content << "```"
  elsif example.respond_to?(:message) && example.respond_to?(:prompt)
    # Handle response objects
    content << "```ruby"
    content << "# Response object"
    content << "#<#{example.class.name}:0x#{example.object_id.to_s(16)}"
    content << "  @message=#{example.message.inspect}"
    content << "  @prompt=#<#{example.prompt.class.name}:0x#{example.prompt.object_id.to_s(16)} ...>"
    content << "  @content_type=#{example.message.content_type.inspect}"
    content << "  @raw_response={...}>"
    content << ""
    content << "# Message content"
    content << "response.message.content # => #{example.message.content.inspect}"
    content << "```"
  else
    content << "```ruby"
    content << ActiveAgent.filter_credential_keys(example.to_s)
    content << "```"
  end
  
  File.write(file_path, content.join("\n"))
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
