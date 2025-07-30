require "test_helper"

# Base class for all configuration-related tests
# Provides common setup/teardown to ensure proper isolation
class BaseConfigurationTest < ActiveSupport::TestCase
  def setup
    # Deep clone the original config to avoid reference issues
    @original_config = ActiveAgent.config.deep_dup
    @original_rails_env = ENV["RAILS_ENV"]
    
    # Ensure we start with a clean state
    ENV["RAILS_ENV"] = "test"
    
    # Call child class setup if defined
    super if defined?(super)
  end

  def teardown
    # Call child class teardown first if defined
    super if defined?(super)
    
    # Always restore to the original state
    ENV["RAILS_ENV"] = @original_rails_env || "test"
    
    # Force reload the configuration from the yml file
    ActiveAgent.instance_variable_set(:@config, nil)
    ActiveAgent.load_configuration(Rails.root.join("config/active_agent.yml"))
  end

  protected

  # Helper method to create a temporary config file for testing
  def with_temp_config_file(content)
    temp_file = Tempfile.new(["active_agent_test", ".yml"])
    temp_file.write(content)
    temp_file.close
    
    yield temp_file.path
  ensure
    temp_file&.unlink
  end

  # Helper to reset configuration to empty state
  def reset_configuration!
    ActiveAgent.instance_variable_set(:@config, nil)
  end
end