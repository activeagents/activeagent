# frozen_string_literal: true

module ActionAgent
  # Rails engine for the Active Agent dashboard: the agent builder, runs,
  # conversations, evaluations, traces, metrics, sandboxes and session
  # recordings, plus the trace ingest API and the MCP server facade.
  #
  # Mount it wherever you like:
  #   mount ActionAgent::Engine => "/agents"
  #
  class Engine < ::Rails::Engine
    isolate_namespace ActionAgent

    engine_name "action_agent"

    config.action_agent = ActiveSupport::OrderedOptions.new

    # The dashboard's JS and CSS ship prebuilt in the gem. Adding the
    # directory to the host app's asset paths is what lets a plain
    # `mount ActionAgent::Engine` work without the host running a
    # JavaScript build — or having a JavaScript build at all.
    # Provider credentials and API keys are posted to the dashboard in the
    # clear and encrypted at rest — filtering keeps them out of the request
    # logs in between, where the gem would otherwise print them verbatim.
    initializer "action_agent.filter_parameters" do |app|
      app.config.filter_parameters += [ :credential, :api_key, :access_token ]
    end

    initializer "action_agent.assets", before: :append_assets_path do |app|
      builds = root.join("app", "assets", "builds").to_s
      next unless File.directory?(builds)

      next unless app.config.respond_to?(:assets)

      if app.config.assets.respond_to?(:paths)
        app.config.assets.paths << builds unless app.config.assets.paths.include?(builds)
      end

      # Sprockets serves only what it was told to precompile, and the host's
      # manifest.js cannot know about an engine's bundles. Without this the
      # layout's stylesheet_link_tag/javascript_include_tag raise
      # AssetNotPrecompiled in development and AssetNotFound in production —
      # i.e. the dashboard's only page 500s on every sprockets-rails host.
      # Propshaft serves everything on the load path and has no precompile
      # list, so the respond_to? check is what distinguishes them.
      if app.config.assets.respond_to?(:precompile)
        app.config.assets.precompile |= %w[action_agent.js action_agent.css]
      end
    end
  end
end
