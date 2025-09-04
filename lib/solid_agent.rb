# frozen_string_literal: true

require "active_support"
require "active_record"
require "solid_agent/version"
require "solid_agent/engine" if defined?(Rails)

# SolidAgent provides ActiveRecord persistence for ActiveAgent
# It tracks conversations, messages, prompts, and generation metrics
module SolidAgent
  extend ActiveSupport::Autoload

  autoload :Configuration
  autoload :Persistable
  autoload :Trackable
  
  module Models
    extend ActiveSupport::Autoload
    
    autoload :Agent
    autoload :AgentConfig
    autoload :Prompt
    autoload :PromptVersion
    autoload :Conversation
    autoload :Message
    autoload :Action
    autoload :Generation
    autoload :Evaluation
    autoload :UsageMetric
  end

  module Concerns
    extend ActiveSupport::Autoload
    
    autoload :Evaluatable
    autoload :Versionable
    autoload :Trackable
  end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def table_name_prefix
      configuration.table_name_prefix
    end
  end
end