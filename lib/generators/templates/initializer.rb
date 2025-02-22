# frozen_string_literal: true

# Configure ActiveAgent
ActiveAgent.configure do |config|
  # Load configuration from config/active_agent.yml
  config.load_configuration Rails.root.join("config", "active_agent.yml")

  # Configure default provider settings
  config.default_provider = :openai
  
  # Configure default generation settings
  config.default_generation_settings = {
    temperature: 0.7,
    top_p: 1.0,
    frequency_penalty: 0.0,
    presence_penalty: 0.0
  }

  # Configure default embedding settings
  config.default_embedding_settings = {
    dimensions: 1536
  }

  # Configure test mode - when true, will use mock responses
  config.test_mode = Rails.env.test?

  # Configure logging
  config.logger = Rails.logger
  config.log_level = Rails.env.production? ? :info : :debug

  # Configure cache
  config.cache = Rails.cache
end