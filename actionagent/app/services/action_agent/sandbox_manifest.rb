# frozen_string_literal: true

module ActionAgent
  # The runtime manifest: how a booted checkout tells the sandbox backend
  # where its MCP facade answers and which bearer token opens it, and which
  # of the app's models an assistant could be given tools over.
  #
  #   { "mcp_path": "/activeagents/mcp", "mcp_token": "aa_...",
  #     "models": [{ "name": "Reservation", "table": "reservations",
  #                  "columns": [{ "name": "status", "type": "string" }] }] }
  #
  # The checked-out app writes it with `bin/rails action_agent:sandbox:manifest`
  # (it mounts this engine, so the task ships with it), and a backend reads it
  # back with .parse. Both halves live here so they cannot drift.
  #
  # Writing it also mirrors the checkout's agent classes into its dashboard
  # (AgentSync), so the facade serves their run_<slug> tools to the key it
  # names. The key and the agents each belong to the only record of the class
  # their model is owned through, when there is exactly one (see
  # .sandbox_owner), and to nobody in an app with no owner model.
  module SandboxManifest
    # Where the manifest task writes, when set; stdout otherwise.
    PATH_ENV = "ACTION_AGENT_SANDBOX_MANIFEST"
    MAX_MODELS = 200
    MAX_COLUMNS = 150
    # The namespaces of models an app gets from Rails and these gems rather
    # than writes itself.
    FRAMEWORK_NAMESPACES = %w[ActionAgent:: SolidAgent:: ActiveAgent:: ActiveStorage:: ActionText:: ActionMailbox:: ActiveRecord::].freeze
    # The dashboard API key the manifest hands out, created once per checkout.
    KEY_NAME = "Checkout sandbox runtime"
    # Column names that look like they hold a credential:
    # ActiveAgent::SchemaTools::SECRET_COLUMNS, or the same pattern under a
    # framework release that predates the constant, which an app can bundle
    # beside this engine.
    SECRET_COLUMNS =
      if defined?(ActiveAgent::SchemaTools) && ActiveAgent::SchemaTools.const_defined?(:SECRET_COLUMNS, false)
        ActiveAgent::SchemaTools::SECRET_COLUMNS
      else
        /password|digest|token|secret|api_key|otp|encrypted|ssn/i
      end

    class Error < StandardError; end

    module_function

    # Builds the manifest inside the booted app: the engine's MCP path under
    # wherever the app mounts it, and an API key for the MCP facade. Also
    # syncs the app's agent classes. A class that cannot be synced is
    # reported on stderr, and the manifest is written regardless.
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

      key = api_key(sandbox_owner(ActionAgent::ApiKey))
      sync_agents(agent_classes || checkout_agent_classes, sandbox_owner(ActionAgent::Agent))
      { "mcp_path" => "#{mount}/mcp", "mcp_token" => key.token, "models" => app_models }
    end

    # The app's own models under app/models that have a table, each with its
    # columns but +id+ and those that look like secrets (SECRET_COLUMNS), at
    # most MAX_MODELS models of MAX_COLUMNS columns. Empty when they cannot
    # be loaded, which is reported on stderr.
    #
    # @return [Array<Hash>] [{ "name" =>, "table" =>, "columns" => [{ "name" =>, "type" => }] }]
    def app_models(root = Rails.root.join("app", "models"))
      return [] unless defined?(ActiveRecord::Base) && root.directory?

      begin
        Rails.autoloaders.main.eager_load_dir(root.to_s)
      rescue StandardError, ScriptError => e
        warn "[ActionAgent] sandbox manifest: could not load app/models: #{e.class}: #{e.message}"
      end

      roots = [ root.to_s, File.realpath(root) ].uniq.map { |dir| "#{dir.chomp("/")}/" }
      models = ActiveRecord::Base.descendants.select { |klass| app_model?(klass, roots) }.sort_by(&:name).first(MAX_MODELS)
      models.filter_map do |klass|
        columns = klass.columns.reject { |column| column.name == "id" || SECRET_COLUMNS.match?(column.name) }
        { "name" => klass.name, "table" => klass.table_name,
          "columns" => columns.first(MAX_COLUMNS).map { |column| { "name" => column.name, "type" => column.type.to_s } } }
      rescue StandardError => e
        warn "[ActionAgent] sandbox manifest: could not read #{klass.name}'s columns: #{e.class}: #{e.message}"
        nil
      end
    end

    def app_model?(klass, roots)
      return false if klass.name.blank? || klass.abstract_class? || klass.name.include?("HABTM_")
      return false if FRAMEWORK_NAMESPACES.any? { |namespace| klass.name.start_with?(namespace) }

      file, = Object.const_source_location(klass.name)
      file && roots.any? { |dir| file.start_with?(dir) || File.realpath(file).start_with?(dir) } && klass.table_exists?
    rescue NameError, SystemCallError, ActiveRecord::ActiveRecordError
      false
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

    # The record the checkout's +model+ rows belong to: the only one of the
    # class +model+ is owned through. The API key and the agents can be owned
    # through different classes (an account and a user), so each is resolved
    # on its own. Nil when the app configures no owner class for +model+, and
    # when that class has no record or several, since a sandbox cannot tell
    # whose it would be.
    #
    # @param model [Class] an Ownable model
    # @return [ActiveRecord::Base, nil]
    def sandbox_owner(model)
      owner_class = owner_class_for(model)
      return nil if owner_class.nil?

      owners = owner_class.limit(2).to_a
      owners.first if owners.one?
    end

    def owner_class_for(model)
      association = model.owner_association
      association && ActionAgent.public_send(Ownable::CLASS_FOR.fetch(association)).safe_constantize
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
          "#{owner_class_for(ActionAgent::Agent)&.name || "an owner model"} and has no single owner for a sandbox to use"
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

    # Reads a manifest a checkout wrote. Its "models" are kept as far as they
    # have the shape .app_models gives them: an entry that does not is
    # dropped, and a manifest written before the list existed has none.
    #
    # @param json [String]
    # @return [Hash] with "mcp_path", "mcp_token" and "models"
    def parse(json)
      data = JSON.parse(json.to_s)
      raise Error, "the manifest is not a JSON object" unless data.is_a?(Hash)

      path = data["mcp_path"]
      unless path.is_a?(String) && path.start_with?("/")
        raise Error, "the manifest names no mcp_path (expected a path such as /activeagents/mcp)"
      end

      token = data["mcp_token"]
      raise Error, "the manifest's mcp_token is not a string" unless token.nil? || token.is_a?(String)

      { "mcp_path" => path, "mcp_token" => token, "models" => parse_models(data["models"]) }
    rescue JSON::ParserError => e
      raise Error, "the manifest is not JSON (#{e.message.truncate(120)})"
    end

    def parse_models(value)
      Array(value).first(MAX_MODELS).filter_map do |entry|
        next unless entry.is_a?(Hash) && SandboxBootSpec::MODEL_NAME.match?(entry["name"].to_s)

        columns = Array(entry["columns"]).first(MAX_COLUMNS).filter_map do |column|
          next unless column.is_a?(Hash) && SandboxBootSpec::COLUMN_NAME.match?(column["name"].to_s)
          next if SECRET_COLUMNS.match?(column["name"])

          { "name" => column["name"], "type" => column["type"].to_s.truncate(32) }
        end
        { "name" => entry["name"], "table" => entry["table"].to_s.truncate(128), "columns" => columns }
      end
    end
  end
end
