require "yaml"
require "active_agent/version"
require "active_support"
require "active_agent/action_prompt/prompt_helper"

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
