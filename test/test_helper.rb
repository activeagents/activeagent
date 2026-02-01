# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

begin
  require "debug"
  require "pry"
  require "pry-doc"
  require "pry-byebug"
rescue LoadError
end

require "jbuilder"
require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
require "rails/test_help"
require "vcr"
require "webmock/minitest"
require "minitest/mock"

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

  # Azure OpenAI credentials
  config.filter_sensitive_data("AZURE_API_KEY")      { ENV["AZURE_OPENAI_API_KEY"] }
  config.filter_sensitive_data("AZURE_RESOURCE")     { ENV["AZURE_OPENAI_RESOURCE"] }
  config.filter_sensitive_data("AZURE_DEPLOYMENT")   { ENV["AZURE_OPENAI_DEPLOYMENT_ID"] }

  # Filter Azure resource name from URLs
  if ENV["AZURE_OPENAI_RESOURCE"]
    config.filter_sensitive_data("azure-resource") { ENV["AZURE_OPENAI_RESOURCE"] }
  end
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
    when :azure, :azure_openai
      has_azure_openai_credentials?
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

  def has_azure_openai_credentials?
    ENV["AZURE_OPENAI_API_KEY"].present? &&
      ENV["AZURE_OPENAI_RESOURCE"].present? &&
      ENV["AZURE_OPENAI_DEPLOYMENT_ID"].present?
  end
end
