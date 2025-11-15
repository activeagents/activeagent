# frozen_string_literal: true

require "rails/engine"

module ActivePrompt
  class Engine < ::Rails::Engine
    isolate_namespace ActivePrompt

    # Ensures the engine's app/ is eager loaded in production and autoloaded in dev/test
    config.autoload_paths << root.join("lib").to_s

    # Keep generated files tidy (no assets/helpers/tests by default from generators)
    config.generators do |g|
      g.assets false
      g.helper false
      g.test_framework :rspec, fixture: false if defined?(RSpec)
    end

    # Sprockets / asset pipeline configuration
    initializer "active_prompt.assets.precompile" do |app|
      # When the engine is used within a host Rails app, ensure our assets are precompiled
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app", "assets")
        app.config.assets.precompile += %w[
          active_prompt/application.js
          active_prompt/application.css
        ]
      end
    end

    # Make sure the engine’s translations are available
    initializer "active_prompt.i18n" do
      config.i18n.load_path += Dir[root.join("config", "locales", "**", "*.yml")]
    end
  end
end
