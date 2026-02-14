# frozen_string_literal: true

require "rails"

module ActivePrompt
  class Engine < ::Rails::Engine
    isolate_namespace ActivePrompt

    initializer "active_prompt.assets.paths_and_precompile" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app", "assets")
        app.config.assets.precompile += %w[
          active_prompt/*
        ]
      end
    end

    initializer "active_prompt.append_migrations" do |app|
      unless app.root.to_s.start_with?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end
  end
end
