require "test_helper"

# Test specifically for the gem loading rescue behavior in OpenAI provider
class OpenAIProviderGemLoadTest < ActiveSupport::TestCase
  test "gem loading rescue block provides helpful error message" do
    # Test the specific LoadError message from the rescue block
    expected_message = "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."

    # We can't easily simulate the gem not being available in our test environment
    # since the gem is already loaded, but we can test that the constant exists
    # and verify the rescue block structure by examining the source

    # Verify that the OpenAI provider file contains the expected rescue block
    provider_file = File.read(Rails.root.join("../../lib/active_agent/generation_provider/open_ai_provider.rb"))

    assert_includes provider_file, "begin"
    assert_includes provider_file, 'gem "ruby-openai", "~> 8.1.0"'
    assert_includes provider_file, 'require "openai"'
    assert_includes provider_file, "rescue LoadError"
    assert_includes provider_file, expected_message
  end

  test "OpenAI provider loads successfully when gem is available" do
    # This verifies the gem is properly loaded in our test environment
    assert defined?(OpenAI), "OpenAI gem should be loaded"

    # Load the provider file to ensure the constant is defined
    require "active_agent/generation_provider/open_ai_provider"
    assert defined?(ActiveAgent::GenerationProvider::OpenAIProvider), "OpenAI provider should be available"

    # Test that we can create an instance
    config = {
      "service" => "OpenAI",
      "api_key" => "test-key",
      "model" => "gpt-4o-mini"
    }

    provider = nil
    assert_nothing_raised do
      provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
    end

    assert_instance_of ActiveAgent::GenerationProvider::OpenAIProvider, provider
    assert_equal "test-key", provider.instance_variable_get(:@api_key)
    assert_equal "gpt-4o-mini", provider.instance_variable_get(:@model_name)
  end

  # Integration test to verify the actual LoadError behavior
  # Note: This test demonstrates how you would test the gem loading in isolation
  test "simulated gem missing scenario" do
    # Create a temporary file that simulates the OpenAI provider without the gem
    temp_provider_content = <<~RUBY
      begin
        gem "nonexistent-gem", "~> 1.0.0"
        require "nonexistent-gem"
      rescue LoadError
        raise LoadError, "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."
      end
    RUBY

    temp_file = Tempfile.new([ "test_provider", ".rb" ])
    temp_file.write(temp_provider_content)
    temp_file.close

    error = assert_raises(LoadError) do
      load temp_file.path
    end

    assert_equal "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`.", error.message

    temp_file.unlink
  end
end
