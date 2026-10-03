# frozen_string_literal: true

module ActionAgent
  # The runtime manifest: how a booted checkout tells the sandbox backend
  # where its MCP facade answers and which bearer token opens it.
  #
  #   { "mcp_path": "/activeagents/mcp", "mcp_token": "aa_..." }
  #
  # The checked-out app writes it with `bin/rails action_agent:sandbox:manifest`
  # (it mounts this engine, so the task ships with it), and a backend reads it
  # back with .parse. Both halves live here so they cannot drift.
  #
  # Writing it also mirrors the checkout's agent classes into its dashboard
  # (AgentSync), so the facade serves their run_<slug> tools to the key it
  # names. Both belong to the checkout's single owner when it has exactly one
  # (see .sandbox_owner), and to nobody in an app with no owner model.
  module SandboxManifest
    # Where the manifest task writes, when set; stdout otherwise.
    PATH_ENV = "ACTION_AGENT_SANDBOX_MANIFEST"
    # The dashboard API key the manifest hands out, created once per checkout.
    KEY_NAME = "Checkout sandbox runtime"

    class Error < StandardError; end

    module_function

    # Builds the manifest inside the booted app: the engine's MCP path under
    # wherever the app mounts it, and an API key for the MCP facade. Syncs
    # the app's agent classes first; a class that cannot be synced is
    # reported on stderr and the manifest is written regardless.
    #
    # @param routes [ActionDispatch::Routing::RouteSet] the app's routes
    # @param agent_classes [Array<Class>, nil] what to sync; nil for
    #   .checkout_agent_classes
    # @return [Hash{String => String}]
    def generate(routes: Rails.application.routes, agent_classes: nil)
      # Rails 8 loads routes lazily in development and test; the mount is
      # invisible until they are.
      Rails.application.reload_routes_unless_loaded if Rails.application.respond_to?(:reload_routes_unless_loaded)

      mount = ActiveAgent::Telemetry::Configuration.new.mount_path_in(routes)
      raise Error, "ActionAgent::Engine is not mounted in this app's routes" if mount.nil?

      owner = sandbox_owner
      key = api_key(owner)
      sync_agents(agent_classes || checkout_agent_classes, owner)
      { "mcp_path" => "#{mount}/mcp", "mcp_token" => key.token }
    end

    # The checkout's own dashboard API key for the facade. Reused across
    # runs so a re-run manifest does not mint a key per boot. A key without
    # an owner takes +owner+ when there is one. In an app that owns keys by
    # account or user and has no single owner, the key has none and reaches
    # no agents over MCP.
    def api_key(owner = nil)
      key = ActionAgent::ApiKey.find_or_initialize_by(name: KEY_NAME)
      key.owner = owner if owner && key.owner.nil?
      key.save! if key.new_record? || key.changed?
      key
    end

    # The record the checkout's agents and key belong to: the only one of
    # ActionAgent.owner_class. Nil without an owner model, and when the app
    # has none or several, since a sandbox cannot tell whose it would be.
    def sandbox_owner
      owner_class = ActionAgent.owner_class
      return nil if owner_class.nil?

      owners = owner_class.limit(2).to_a
      owners.first if owners.one?
    end

    # The app's own agent classes: those defined under app/agents, except
    # ApplicationAgent and abstract ones.
    #
    # @param root [Pathname] where the app keeps its agents
    # @return [Array<Class>]
    def checkout_agent_classes(root = Rails.root.join("app", "agents"))
      return [] unless defined?(ActiveAgent::Base) && root.directory?

      loader = Rails.autoloaders.main
      Dir[root.join("**", "*.rb").to_s].sort.each do |path|
        loader.load_file(path)
      rescue StandardError, ScriptError => e
        warn "[ActionAgent] sandbox manifest: could not load #{path}: #{e.class}: #{e.message}"
      end

      roots = [ root.to_s, File.realpath(root) ].uniq.map { |dir| "#{dir.chomp("/")}/" }
      ActiveAgent::Base.descendants.select do |klass|
        next false if klass.name.blank? || klass.abstract? || klass.name == "ApplicationAgent"

        file, = Object.const_source_location(klass.name)
        file && roots.any? { |dir| file.start_with?(dir) || File.realpath(file).start_with?(dir) }
      rescue NameError, SystemCallError
        false
      end.sort_by(&:name)
    end

    # Syncs each class on its own, so one that cannot be synced (a provider
    # gem the checkout lacks, say) leaves the rest synced.
    def sync_agents(classes, owner)
      if owner.nil? && ActionAgent::Agent.owner_association
        warn "[ActionAgent] sandbox manifest: no agents synced: the app owns agents by " \
          "#{ActionAgent.owner_class&.name || "an owner model"} and has no single owner for a sandbox to use"
        return
      end

      classes.each do |klass|
        result = ActionAgent::AgentSync.call([ klass ], owner: owner)
        warn "[ActionAgent] sandbox manifest: could not sync #{klass.name}: #{result.errors}" unless result.success?
        result.skipped.each { |row| warn "[ActionAgent] sandbox manifest: skipped #{row.skipped}" }
      rescue StandardError => e
        warn "[ActionAgent] sandbox manifest: could not sync #{klass.name}: #{e.class}: #{e.message}"
      end
    end

    # Reads a manifest a checkout wrote.
    #
    # @param json [String]
    # @return [Hash{String => String}] with "mcp_path" and "mcp_token"
    def parse(json)
      data = JSON.parse(json.to_s)
      raise Error, "the manifest is not a JSON object" unless data.is_a?(Hash)

      path = data["mcp_path"]
      unless path.is_a?(String) && path.start_with?("/")
        raise Error, "the manifest names no mcp_path (expected a path such as /activeagents/mcp)"
      end

      token = data["mcp_token"]
      raise Error, "the manifest's mcp_token is not a string" unless token.nil? || token.is_a?(String)

      { "mcp_path" => path, "mcp_token" => token }
    rescue JSON::ParserError => e
      raise Error, "the manifest is not JSON (#{e.message.truncate(120)})"
    end
  end
end
