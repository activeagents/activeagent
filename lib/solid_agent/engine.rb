# frozen_string_literal: true

module SolidAgent
  class Engine < ::Rails::Engine
    isolate_namespace SolidAgent

    config.generators do |g|
      g.test_framework :rspec
      g.fixture_replacement :factory_bot
      g.factory_bot dir: "spec/factories"
    end

    initializer "solid_agent.load_models" do
      ActiveSupport.on_load(:active_record) do
        require "solid_agent/models/agent"
        require "solid_agent/models/agent_config"
        require "solid_agent/models/prompt"
        require "solid_agent/models/prompt_version"
        require "solid_agent/models/conversation"
        require "solid_agent/models/message"
        require "solid_agent/models/action"
        require "solid_agent/models/generation"
        require "solid_agent/models/evaluation"
        require "solid_agent/models/usage_metric"
      end
    end

    initializer "solid_agent.active_agent_integration" do
      ActiveSupport.on_load(:active_agent) do
        require "solid_agent/persistable"
        ActiveAgent::Base.include(SolidAgent::Persistable)
      end
    end

    config.to_prepare do
      # Ensure concerns are loaded
      Dir.glob(Engine.root.join("app", "models", "solid_agent", "concerns", "*.rb")).each do |file|
        require_dependency file
      end
    end
  end
end