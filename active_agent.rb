require "active_support"
require "yaml"
require_relative "active_agent/action_prompt"
require_relative "active_agent/generation_provider"

require_relative "active_agent/version"

module ActiveAgent
  extend ActiveSupport::Autoload

  autoload :Base
  autoload :Callbacks
  autoload :ActionPrompt
  autoload :Parameterized
  autoload :Generation
  autoload :GenerationProvider
  autoload :GenerationJob
  autoload :QueuedGeneration

  class << self
    attr_accessor :config

    def configure
      yield self
    end

    def load_configuration(file)
      config_file = YAML.load_file(file, aliases: true)
      env = ENV["RAILS_ENV"] || ENV["ENV"] || "development"
      @config = config_file[env] || config_file
    end
  end
end
