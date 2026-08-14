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

    # The controllers under app/controllers/action_agent/api are ActionAgent::Api,
    # but an engine's files are autoloaded by the host's `rails.main` loader,
    # under the host's inflections. A host that declares `inflect.acronym "API"`
    # — common enough that Rails documents it — makes Zeitwerk expect
    # ActionAgent::API::TracesController in a file that defines
    # ActionAgent::Api::TracesController, and every request to the mount raises
    # Zeitwerk::NameError.
    #
    # Scoped to this engine's own path rather than set through `inflect`: the
    # loader is shared, so a blanket rule would re-spell the host's own API
    # constants. `camelize` receives the absolute path, which is the only hook
    # that can tell this engine's api/ from the host's.
    initializer "action_agent.inflections", before: :set_autoload_paths do
      engine_root = root.to_s

      Rails.autoloaders.main.inflector.singleton_class.prepend(Module.new do
        define_method(:camelize) do |basename, abspath|
          next "Api" if basename == "api" && abspath.to_s.start_with?(engine_root)

          super(basename, abspath)
        end
      end)
    end

    # Rails resolves a route's controller by camelizing the stored path
    # ("action_agent/api/traces") with the host's *global* inflections, and no
    # engine-level setting scopes that — so an acronym host looks up
    # ActionAgent::API::TracesController and raises NameError even though the
    # autoloader named the module correctly above. No single spelling satisfies
    # both kinds of host: a plain host camelizes to Api, an acronym host to API.
    # So the namespace answers to both. `const_missing` rather than an eager
    # alias because the controllers are autoloaded on demand, and naming them at
    # boot would load the whole dashboard.
    ActionAgent.singleton_class.prepend(Module.new do
      def const_missing(name)
        return const_get(:Api) if name == :API

        super
      end
    end)

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
