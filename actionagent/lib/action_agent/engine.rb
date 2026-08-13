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
    initializer "action_agent.assets", before: :append_assets_path do |app|
      builds = root.join("app", "assets", "builds").to_s
      next unless File.directory?(builds)

      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << builds unless app.config.assets.paths.include?(builds)
      end
    end
  end
end
