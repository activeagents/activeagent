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

    # Basenames this engine spells differently from Zeitwerk's default
    # camelization, consulted by the inflections initializer below. An engine
    # file that wants a genuine acronym in its constant adds its basename here
    # rather than relying on the host to register one.
    INFLECTION_OVERRIDES = { "mcp_catalog" => "MCPCatalog" }.freeze

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

    # This engine's constants are spelled the way Zeitwerk's own inflector
    # spells them — Api, ApiKey — but an engine's files are
    # autoloaded by the host's `rails.main` loader, under the *host's*
    # inflections. A host that declares `inflect.acronym "API"` or "MCP" (both
    # common, and documented by Rails) makes Zeitwerk expect
    # ActionAgent::API::TracesController from a file
    # that defines ActionAgent::Api::TracesController. The constant never
    # resolves and the request raises Zeitwerk::NameError.
    #
    # Every path under this engine therefore camelizes with Zeitwerk's default
    # rules, ignoring whatever acronyms the host has registered. Applied by
    # path rather than through `inflect`: the loader is shared with the host,
    # so a blanket rule would re-spell the host's own constants. `camelize`
    # receives the absolute path, which is the only hook that can tell this
    # engine's files from the host's.
    #
    # Basenames whose spelling this engine cannot express through default
    # camelization (a genuine acronym it wants uppercased) go in
    # INFLECTION_OVERRIDES.
    initializer "action_agent.inflections", before: :set_autoload_paths do
      engine_root = File.join(root.to_s, "")
      default = Zeitwerk::Inflector.new

      Rails.autoloaders.main.inflector.singleton_class.prepend(Module.new do
        define_method(:camelize) do |basename, abspath|
          next super(basename, abspath) unless abspath.to_s.start_with?(engine_root)

          ActionAgent::Engine::INFLECTION_OVERRIDES.fetch(basename) { default.camelize(basename, abspath) }
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
    # The router does not consult the autoloader's inflector, so an acronym
    # host asks for ActionAgent::API::MCPServersController while the constants
    # are Api::McpServersController. Rather than enumerate the pairs, an
    # all-caps run in a missing constant is retried in the spelling default
    # camelization produces: API -> Api, MCPServersController -> McpServers-
    # Controller. Only the engine's own namespaces are touched, and only for a
    # constant that is already missing.
    inflection_shim = Module.new do
      def const_missing(name)
        relaxed = name.to_s.gsub(/([A-Z])([A-Z]+)(?=[A-Z][a-z]|\d|\z)/) { "#{$1}#{$2.downcase}" }

        return super if relaxed == name.to_s || !const_defined?(relaxed, false)

        const_get(relaxed, false)
      end
    end

    ActionAgent.singleton_class.prepend(inflection_shim)

    # ActionAgent::Api is autoloaded, so it cannot be reopened at this point.
    # Zeitwerk hands it over as soon as it is defined, which is before the
    # router can ask it for a controller.
    initializer "action_agent.api_inflection_shim" do
      Rails.autoloaders.main.on_load("ActionAgent::Api") do |mod, _abspath|
        mod.singleton_class.prepend(inflection_shim)
      end
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
