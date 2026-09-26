# frozen_string_literal: true

module ActionAgent
  # The database a :local sandbox boots on, unless its sandbox.yml says
  # otherwise. A checkout of the app the dashboard itself runs names the same
  # development database in its config/database.yml, and its `db:prepare`
  # would migrate the developer's own; so every sandbox gets databases of its
  # own, through the variables Rails merges over database.yml
  # (ActiveRecord::DatabaseConfigurations#environment_value_for):
  # DATABASE_URL for the `primary` entry, <NAME>_DATABASE_URL for any other
  # (QUEUE_DATABASE_URL for Solid Queue's `queue`).
  #
  # Only the adapter and database names are read, from the checkout's
  # config/database.yml, and nothing of the checkout runs in the dashboard:
  # ERB tags are blanked out rather than evaluated, and the YAML is read with
  # safe_load. What is left over is enough to know the adapter, which is
  # all a URL needs; the host, user and password stay whatever database.yml
  # or the process environment (PGHOST and the like) say, because Rails
  # merges a URL over the entry rather than replacing it.
  #
  #   sqlite3            sqlite3:<workspace>/db/<env>[_<name>].sqlite3, removed with the workspace
  #   postgresql/postgis postgresql:///<database>_sandbox_<short id>, dropped on terminate
  #   mysql2/trilogy     mysql2:///<database>_sandbox_<short id>, dropped on terminate
  #
  # Any variable the sandbox.yml env sets is left to it.
  class LocalSandboxDatabases
    CONFIG_PATH = File.join("config", "database.yml")
    # Larger than any database.yml; a checkout could point the path anywhere.
    MAX_CONFIG_BYTES = 256 * 1024
    # Stands in for every <%= %> output. Not an identifier, so a database
    # name built from ERB is never mistaken for a real one.
    ERB_OUTPUT = "(erb)"
    ERB_TAG = /<%(?!%)(=|-|\#)?.*?-?%>/m
    FILE_ADAPTERS = %w[sqlite3].freeze
    SERVER_ADAPTERS = %w[postgresql postgis mysql2 trilogy].freeze
    # PostgreSQL cuts identifiers at 63 bytes, MySQL at 64.
    MAX_DATABASE_NAME = 63
    IDENTIFIER = /\A[A-Za-z0-9_]+\z/
    ENTRY_NAME = /\A[A-Za-z][A-Za-z0-9_]*\z/

    # What the backend does with a checkout's databases.
    #
    # env      the variables to add to every boot step's environment
    # drop     whether terminate drops them (server databases)
    # notes    one line per decision, for the setup log
    Plan = Struct.new(:env, :drop, :notes, keyword_init: true) do
      def empty?
        env.empty?
      end
    end

    # @param app [Pathname] the checkout
    # @param workspace [Pathname] the sandbox's workspace
    # @param session_id [String]
    # @param overrides [Hash] the sandbox.yml env: what it sets is its own
    # @param fallback_name [String, nil] a database name base when
    #   database.yml gives none (the repository's name)
    # @return [Plan]
    def self.plan(app:, workspace:, session_id:, overrides: {}, fallback_name: nil)
      new(app: app, workspace: workspace, session_id: session_id, overrides: overrides, fallback_name: fallback_name).plan
    end

    def initialize(app:, workspace:, session_id:, overrides:, fallback_name:)
      @app = Pathname(app)
      @workspace = Pathname(workspace)
      @session_id = session_id.to_s
      @overrides = overrides.to_h
      @fallback_name = fallback_name
      @notes = []
    end

    def plan
      env = {}
      drop = false
      entries = read_entries
      primary_url = nil

      entries&.each do |name, config|
        variable = name == "primary" ? "DATABASE_URL" : "#{name.upcase}_DATABASE_URL"
        next note("#{variable}: left to .activeagents/sandbox.yml") if @overrides.key?(variable)

        url, server = url_for(name, config, primary_url)
        next unless url

        primary_url ||= url
        env[variable] = url
        drop ||= server
        note("#{variable}=#{url}")
      end

      # db:prepare and db:drop in development also reach the test
      # database, unless DATABASE_URL is set; that one is the developer's.
      env["SKIP_TEST_DATABASE"] = "1" if env.any? && !@overrides.key?("SKIP_TEST_DATABASE")
      Plan.new(env: env, drop: drop, notes: @notes)
    end

    private

    def rails_env
      @overrides["RAILS_ENV"].presence || @overrides["RACK_ENV"].presence || "development"
    end

    # [[name, config], ...] for the Rails environment the sandbox boots in,
    # or nil when database.yml cannot say.
    def read_entries
      text = read_config
      return nil unless text

      data = begin
        YAML.safe_load(text.gsub(ERB_TAG) { ::Regexp.last_match(1) == "=" ? ERB_OUTPUT : "" }, aliases: true)
      rescue Psych::Exception
        nil
      end
      return adapter_from_text(text) unless data.is_a?(Hash)

      config = data[rails_env]
      case config
      when Hash
        if config.any? && config.values.all?(Hash)
          config.select { |name, _| ENTRY_NAME.match?(name.to_s) }.map { |name, entry| [ name.to_s, entry ] }
        else
          [ [ "primary", config ] ]
        end
      when String
        note("#{CONFIG_PATH}: #{rails_env} is a URL, which Rails does not let DATABASE_URL override; set it in .activeagents/sandbox.yml")
        nil
      else
        note("#{CONFIG_PATH}: no #{rails_env} configuration")
        nil
      end
    end

    # A config that does not parse once its ERB is blanked (a tag that
    # emits whole keys) still names its adapter somewhere: the first
    # `adapter:` line, as one primary database.
    def adapter_from_text(text)
      adapter = text[/^\s*adapter:\s*["']?([A-Za-z0-9_]+)/, 1]
      unless adapter
        note("#{CONFIG_PATH}: could not be read without running its ERB; no sandbox database set")
        return nil
      end

      [ [ "primary", { "adapter" => adapter } ] ]
    end

    def read_config
      path = @app.join(CONFIG_PATH)
      return nil unless path.file?

      # Read only inside the checkout: a symlink could name any file the
      # dashboard's user can read.
      real = path.realpath
      unless real.to_s.start_with?("#{@app.realpath}#{File::SEPARATOR}")
        note("#{CONFIG_PATH}: points outside the checkout; not read")
        return nil
      end
      if real.size > MAX_CONFIG_BYTES
        note("#{CONFIG_PATH}: too large to read")
        return nil
      end

      real.read.force_encoding(Encoding::UTF_8).scrub
    rescue SystemCallError
      nil
    end

    # [url, server?] for one entry, or nil when it is left alone.
    def url_for(name, config, primary_url)
      unless config.is_a?(Hash)
        note("#{name}: not a mapping; left alone")
        return nil
      end
      if config.key?("url")
        # A url: entry is a UrlConfig, which Rails merges no variable over.
        note("#{name}: has its own url:, which Rails does not let a variable override; set it in .activeagents/sandbox.yml")
        return nil
      end
      # A replica reads what its primary writes.
      return [ primary_url, false ] if truthy?(config["replica"]) && primary_url
      if config.key?("database_tasks") && !truthy?(config["database_tasks"])
        note("#{name}: database_tasks is off (a database the app does not manage); left alone")
        return nil
      end

      adapter = config["adapter"].to_s
      if FILE_ADAPTERS.include?(adapter)
        [ sqlite_url(name), false ]
      elsif SERVER_ADAPTERS.include?(adapter)
        [ "#{adapter}:///#{database_name(name, config)}", true ]
      else
        what = adapter.empty? || adapter == ERB_OUTPUT ? "its adapter is unknown" : "adapter #{adapter} is not one it knows"
        note("#{name}: #{what}; no sandbox database set")
        Rails.logger.info("[ActionAgent] sandbox #{@session_id}: #{CONFIG_PATH} #{name}: #{what}; its database is left as configured")
        nil
      end
    end

    def truthy?(value)
      value == true || value.to_s == "true"
    end

    # Inside the workspace, so it goes when the workspace does.
    def sqlite_url(name)
      FileUtils.mkdir_p(@workspace.join("db"), mode: 0o700)
      file = @workspace.join("db", name == "primary" ? "#{rails_env}.sqlite3" : "#{rails_env}_#{name}.sqlite3")
      "sqlite3:#{URI::RFC2396_Parser.new.escape(file.to_s)}"
    end

    # <database>_sandbox_<first 8 of the session id>: recognizably the
    # app's, and one per sandbox.
    def database_name(name, config)
      base = config["database"].to_s
      unless IDENTIFIER.match?(base)
        app = @fallback_name.to_s.gsub(/[^A-Za-z0-9_]/, "_").presence || "app"
        base = [ app, rails_env, (name unless name == "primary") ].compact.join("_")
      end
      suffix = "_sandbox_#{@session_id.delete("-").downcase.first(8)}"
      "#{base.first(MAX_DATABASE_NAME - suffix.length)}#{suffix}"
    end

    def note(line)
      @notes << line
      nil
    end
  end
end
