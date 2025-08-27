# frozen_string_literal: true

require "active_agent/schema_generator"

module ActiveAgent
  class SchemaGeneratorRailtie < Rails::Railtie
    initializer "active_agent.schema_generator" do
      ActiveSupport.on_load(:active_record) do
        ActiveRecord::Base.include ActiveAgent::SchemaGenerator
      end

      ActiveSupport.on_load(:active_model) do
        if defined?(ActiveModel::Model)
          ActiveModel::Model.include ActiveAgent::SchemaGenerator
        end
      end
    end
  end
end
