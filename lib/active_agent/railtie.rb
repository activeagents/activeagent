# frozen_string_literal: true

require "active_job/railtie"
require "active_agent"
require "active_agent/engine"
require "rails"
require "abstract_controller/railties/routes_helpers"

module ActiveAgent
  class Railtie < Rails::Railtie # :nodoc:
    config.active_agent = ActiveSupport::OrderedOptions.new
    config.active_agent.preview_paths = []
    config.eager_load_namespaces << ::ActiveAgent

    initializer "active_agent.deprecator", before: :load_environment_config do |app|
      app.deprecators[:active_agent] = ActiveAgent.deprecator
    end

    initializer "active_agent.logger" do
      ActiveSupport.on_load(:active_agent) { self.logger ||= Rails.logger }
    end

    initializer "active_agent.set_configs" do |app|
      paths = app.config.paths
      options = app.config.active_agent

      options.assets_dir ||= paths["public"].first
      options.javascripts_dir ||= paths["public/javascripts"].first
      options.stylesheets_dir ||= paths["public/stylesheets"].first
      options.show_previews = Rails.env.development? if options.show_previews.nil?
      options.cache_store ||= Rails.cache
      options.preview_paths |= ["#{Rails.root}/test/agents/previews"]

      # make sure readers methods get compiled
      options.asset_host ||= app.config.asset_host
      options.relative_url_root ||= app.config.relative_url_root

      ActiveSupport.on_load(:active_agent) do
        include AbstractController::UrlFor
        extend ::AbstractController::Railties::RoutesHelpers.with(app.routes, false)
        include app.routes.mounted_helpers

        register_interceptors(options.delete(:interceptors))
        register_preview_interceptors(options.delete(:preview_interceptors))
        register_observers(options.delete(:observers))
        self.view_paths = ["#{Rails.root}/app/views"]
        self.preview_paths |= options[:preview_paths]

        if (delivery_job = options.delete(:delivery_job))
          self.delivery_job = delivery_job.constantize
        end

        if options.smtp_settings
          self.smtp_settings = options.smtp_settings
        end

        options.each { |k, v| send(:"#{k}=", v) }
      end

      ActiveSupport.on_load(:action_dispatch_integration_test) do
        include ActiveAgent::TestHelper
        include ActiveAgent::TestCase::ClearTestDeliveries
      end
    end

    initializer "active_agent.set_autoload_paths", before: :set_autoload_paths do |app|
      app.config.active_agent
      # app.config.paths["test/agents/previews"].concat(options.preview_paths)
    end

    initializer "active_agent.compile_config_methods" do
      ActiveSupport.on_load(:active_agent) do
        config.compile_methods! if config.respond_to?(:compile_methods!)
      end
    end

    config.after_initialize do |app|
      options = app.config.active_agent

      if options.show_previews
        app.routes.prepend do
          get "/rails/agents" => "rails/agents#index", :internal => true
          get "/rails/agents/download/*path" => "rails/agents#download", :internal => true
          get "/rails/agents/*path" => "rails/agents#preview", :internal => true
        end
      end
    end
  end
end
