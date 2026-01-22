# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# Provide placeholder API keys so provider clients initialize without
# real credentials during cassette-driven tests.
ENV["OPENAI_API_KEY"]          ||= "test-openai-key"
ENV["OPENAI_ACCESS_TOKEN"]     ||= ENV["OPENAI_API_KEY"]
ENV["OPEN_AI_ACCESS_TOKEN"]    ||= ENV["OPENAI_API_KEY"]
ENV["OPEN_ROUTER_ACCESS_TOKEN"] ||= "test-openrouter-key"
ENV["ANTHROPIC_API_KEY"]       ||= "test-anthropic-key"
ENV["ANTHROPIC_ACCESS_TOKEN"]  ||= ENV["ANTHROPIC_API_KEY"]

begin
  require "debug"
  require "pry"
  require "pry-doc"
  require "pry-byebug"
rescue LoadError
end

require "jbuilder"
require_relative "../test/dummy/config/environment"

# Make sure BOTH dummy and engine migrations are available to the test DB
ActiveRecord::Migrator.migrations_paths = [
  File.expand_path("../test/dummy/db/migrate", __dir__),
  File.expand_path("../db/migrate", __dir__)
]

# Proactively migrate both dummy and engine paths (works across AR versions)
begin
  require "active_record"
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Base.establish_connection unless ActiveRecord::Base.connected?

  paths = ActiveRecord::Migrator.migrations_paths

  migration_context =
    begin
      # AR >= ~6 supports single-arg constructor
      ActiveRecord::MigrationContext.new(paths)
    rescue ArgumentError
      # Older AR expects (paths, schema_migration)
      ActiveRecord::MigrationContext.new(paths, ActiveRecord::SchemaMigration)
    end

  migration_context.migrate
rescue ActiveRecord::NoDatabaseError
  # If DB isn't created yet, ignore; the dummy app tasks will handle creation.
end

# Rails still checks consistency after we migrate
ActiveRecord::Migration.maintain_test_schema!

require "rails/test_help"
require "vcr"
require "webmock/minitest"
require "minitest/mock"

# -------------------------------------------------------------------
# 🔧 Test environment hygiene (prevents generator test collisions)
# - Clean any leftover generated files under tmp/generators so they
#   don't get picked up by test discovery in subsequent runs.
# - Remove lingering constants that would cause class-collision checks
#   to abort generator runs (e.g., UserAgentTest).
# -------------------------------------------------------------------
begin
  generated_dir = Rails.root.join("tmp", "generators")
  FileUtils.rm_rf(generated_dir)
rescue => e
  warn "Warning: failed to clean #{generated_dir}: #{e.message}"
end


# Helper to remove a constant by fully qualified name (supports namespaces)
def remove_constant(name)
  names = name.to_s.split("::")
  parent = Object
  names[0..-2].each do |n|
    return unless parent.const_defined?(n, false)
    parent = parent.const_get(n)
  end
  last = names.last
  parent.send(:remove_const, last) if parent.const_defined?(last, false)
end

# Remove any lingering constants that the generator collision check might trip over
%w[
  UserAgentTest
  Admin::UserAgentTest
].each { |const| remove_constant(const) }

# -------------------------------------------------------------------
# A tiny AR model just for tests, to avoid clashing with any non-AR ApplicationAgent
# Uses the dummy's application_agents table.
class PromptTestAgent < ActiveRecord::Base
  self.table_name = "application_agents"

  begin
    require "active_agent/has_context"
    include ActiveAgent::HasContext
    has_context prompts: :prompts, messages: :messages, tools: :actions
  rescue LoadError, NameError
    # If HasContext isn't present in this branch, tests that rely on it should be skipped or guarded.
  end
end
# -------------------------------------------------------------------

# Extract full path and relative path from caller_info
def extract_path_info(caller_info)
  if caller_info =~ /(.+):(\d+):in/
    full_path = $1
    line_number = $2

    # Get relative path from project root
    project_root = File.expand_path("../..", __dir__)
    relative_path = full_path.gsub(project_root + "/", "")

    {
      full_path: full_path,
      relative_path: relative_path,
      line_number: line_number,
      file_name: File.basename(full_path)
    }
  else
    {}
  end
end

def doc_example_output(example = nil, test_name = nil)
  # Extract caller information
  caller_info = caller.find { |line| line.include?("_test.rb") }

  # Extract file path and line number from caller
  if caller_info =~ /(.+):(\d+):in/
    test_file = $1.split("/").last
    line_number = $2
  end

  path_info = extract_path_info(caller_info)
  file_name = path_info[:file_name].dasherize
  test_name ||= name.to_s.dasherize if respond_to?(:name)

  file_path = Rails.root.join("..", "..", "docs", "parts", "examples", "#{file_name}-#{test_name}.md")
  # puts "\nWriting example output to #{file_path}\n"
  FileUtils.mkdir_p(File.dirname(file_path))

  open_local = "vscode://file/#{path_info[:full_path]}:#{path_info[:line_number]}"

  open_remote = "https://github.com/activeagents/activeagent/tree/main#{path_info[:relative_path].gsub("activeagent", "")}#L#{path_info[:line_number]}"

  open_link = ENV["GITHUB_ACTIONS"] ? open_remote : open_local

  # Format the output with metadata
  content = []
  content << "<!-- Generated from #{test_file}:#{line_number} -->"

  content << "[#{path_info[:relative_path]}:#{path_info[:line_number]}](#{open_link})"
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
    content << example.to_s
    content << "```"
  end

  File.write(file_path, content.join("\n"))
end

VCR.configure do |config|
  config.cassette_library_dir = "test/fixtures/vcr_cassettes"
  config.hook_into :webmock

  config.filter_sensitive_data("ACCESS_TOKEN")     { ENV["OPEN_AI_ACCESS_TOKEN"] }
  config.filter_sensitive_data("ORGANIZATION_ID")  { ENV["OPEN_AI_ORGANIZATION_ID"] }
  config.filter_sensitive_data("PROJECT_ID")       { ENV["OPEN_AI_PROJECT_ID"] }
  config.filter_sensitive_data("ACCESS_TOKEN")     { ENV["OPEN_ROUTER_ACCESS_TOKEN"] }
  config.filter_sensitive_data("ACCESS_TOKEN")     { ENV["ANTHROPIC_ACCESS_TOKEN"] }
  config.filter_sensitive_data("GITHUB_MCP_TOKEN") { ENV["GITHUB_MCP_TOKEN"] }
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("test/fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("test/fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

# Base test case that properly manages ActiveAgent configuration
class ActiveAgentTestCase < ActiveSupport::TestCase
  def setup
    super
    # Store original configuration
    @original_config = ActiveAgent.configuration.dup if ActiveAgent.configuration
    @original_rails_env = ENV["RAILS_ENV"]
    # Ensure we're in test environment
    ENV["RAILS_ENV"] = "test"
  end

  def teardown
    super
    # Restore original configuration
    ActiveAgent.instance_variable_set(:@configuration, @original_config) if @original_config
    ENV["RAILS_ENV"] = @original_rails_env
    # Reload default configuration
    config_file = Rails.root.join("config/active_agent.yml")
    ActiveAgent.configuration_load(config_file) if File.exist?(config_file)
  end

  # Helper method to temporarily set configuration
  def with_active_agent_config(config)
    old_config = ActiveAgent.configuration
    ActiveAgent.instance_variable_set(:@configuration, config)
    yield
  ensure
    ActiveAgent.instance_variable_set(:@configuration, old_config)
  end
end

# Add credential check helpers to all tests
class ActiveSupport::TestCase
  # Check if credentials are available for a given provider
  def has_provider_credentials?(provider)
    case provider.to_sym
    when :openai
      has_openai_credentials?
    when :anthropic
      has_anthropic_credentials?
    when :open_router, :openrouter
      has_openrouter_credentials?
    when :ollama
      has_ollama_credentials?
    else
      false
    end
  end

  def has_openai_credentials?
    Rails.application.credentials.dig(:openai, :access_token).present? ||
      ENV["OPENAI_ACCESS_TOKEN"].present? ||
      ENV["OPENAI_API_KEY"].present?
  end

  def has_anthropic_credentials?
    Rails.application.credentials.dig(:anthropic, :access_token).present? ||
      ENV["ANTHROPIC_ACCESS_TOKEN"].present? ||
      ENV["ANTHROPIC_API_KEY"].present?
  end

  def has_openrouter_credentials?
    Rails.application.credentials.dig(:open_router, :access_token).present? ||
      Rails.application.credentials.dig(:open_router, :api_key).present? ||
      ENV["OPENROUTER_API_KEY"].present?
  end

  def has_ollama_credentials?
    # Ollama typically runs locally, so check if it's accessible
    config = ActiveAgent.configuration.dig("ollama") || {}
    host = config["host"] || "http://localhost:11434"

    # For test purposes, we assume Ollama is available if configured
    # In real tests, you might want to actually ping the server
    host.present?
  end
end
