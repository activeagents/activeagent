# frozen_string_literal: true

require "shellwords"

module ActionAgent
  # How a sandbox backend boots one checkout, handed to it as data
  # (SandboxOrchestrator#create_sandbox(session, boot_config:)). For that
  # boot it replaces the checkout's .activeagents/sandbox.yml. #to_h is plain
  # JSON, so a backend that boots somewhere else (a container's own boot
  # script) reads the same thing:
  #
  #   kind             "bootstrap" (built by .bootstrap) or "custom"
  #   apply            "always", or "without_engine": only when the checkout
  #                    has a Gemfile.lock that locks no actionagent and its
  #                    sandbox.yml names no manifest. Otherwise the checkout
  #                    boots as it would without a spec, with only the
  #                    spec's secrets added to its sandbox.yml env.
  #   preflight        refuse, before any repository command runs, a
  #                    checkout without a Gemfile.lock or a
  #                    config/application.rb at its root, or one locking Ruby
  #                    or railties older than the engine supports
  #   steps            [{ name, command, timeout, unless_locked?, if_task? }],
  #                    run in order, each with a log of its own. A step with
  #                    unless_locked is skipped when the checkout's
  #                    Gemfile.lock, as checked out, locks that gem; one with
  #                    if_task when the app defines no such Rake task.
  #   env              environment for the steps, manifest and start
  #   secrets          environment too, masked in every log and message the
  #                    backend produces and never written down
  #   manifest, start  { command, timeout }, as sandbox.yml's keys of the
  #                    same name
  #   start_url        a path on the booted app that must not answer 5xx once
  #                    its MCP facade answers
  #   keep_on_failure  keep a failed boot's workspace and databases, so it
  #                    can be resumed from the step that failed
  #   timeout          seconds for the whole boot, checkout included; a
  #                    step's own timeout bounds it within that
  #   engine           where the gems were taken from (see .engine_gems)
  #
  # Secrets travel in memory only. #redacted is what may be written down: the
  # secrets' names without their values.
  class SandboxBootSpec
    class Invalid < ArgumentError; end

    KINDS = %w[bootstrap custom].freeze
    APPLY_MODES = %w[always without_engine].freeze
    STEP_NAME = /\A[a-z][a-z0-9_]{0,39}\z/
    # Names the backend gives the parts of a boot that are not spec steps.
    RESERVED_STEP_NAMES = %w[checkout preflight setup manifest start server].freeze
    ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    GEM_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/
    TASK_NAME = /\A[A-Za-z0-9_][A-Za-z0-9_:.-]{0,99}\z/
    # Set by the backend, or changing how Ruby, Bundler, Node or git load
    # code: a secret is handed to the checkout's code, never to the loader.
    REFUSED_SECRET_NAME = /
      \A(?:PORT|DATABASE_URL|RUBYOPT|RUBYLIB|LD_PRELOAD|PATH|NODE_OPTIONS)\z |
      _DATABASE_URL\z | \AACTION_AGENT_SANDBOX_ | \ADYLD_ | \ABUNDLE_ | \AGIT_
    /x
    MAX_STEPS = 30
    MAX_COMMAND_LENGTH = 4096
    MAX_START_URL_LENGTH = 2048
    MAX_TIMEOUT = 6 * 3600
    DEFAULT_STEP_TIMEOUT = 600
    # A bootstrap installs a bundle, runs two generators and every engine
    # migration before the app's own setup: more than a configured app needs.
    BOOTSTRAP_TIMEOUT = 1800
    MINIMUM_RUBY = Gem::Version.new("3.2")
    MINIMUM_RAILTIES = Gem::Version.new("7.2")
    ASSET_TASKS = %w[javascript:build css:build tailwindcss:build].freeze
    CREDENTIALED_URL = %r{[a-z][a-z0-9+.-]*://[^/\s@]+@}i
    # What a sandbox request may ask of a checkout's boot (see
    # .request_options): bootstrap one whose Gemfile.lock lacks the engine,
    # bootstrap it whatever its lock says, or boot it as its sandbox.yml says.
    BOOTSTRAP_MODES = %w[auto always never].freeze
    # The steps that install the engine, which a checkout that bundles it
    # already (a project's install pull request branch) does not run.
    INSTALL_STEPS = %w[bundle_config add_framework add_engine install_framework install_engine].freeze
    # A schema tools choice (see .schema_tools_step).
    MODEL_NAME = /\A[A-Z][A-Za-z0-9]{0,99}(?:::[A-Z][A-Za-z0-9]{0,99}){0,4}\z/
    COLUMN_NAME = /\A[a-z_][a-z0-9_]{0,62}\z/
    MAX_SCHEMA_TOOL_MODELS = 50
    MAX_SCHEMA_TOOL_COLUMNS = 100

    attr_reader :kind, :apply, :steps, :env, :secrets, :manifest, :start, :start_url, :timeout, :engine,
      :secret_names

    class << self
      # A spec from +value+: a spec, a Hash in #to_h's shape (string or
      # symbol keys), or nil for none.
      #
      # @raise [Invalid] when +value+ is not a valid spec
      def wrap(value)
        case value
        when nil then nil
        when self then value
        when Hash then new(value)
        else raise Invalid, "a boot spec is a Hash, not #{value.class}"
        end
      end

      # The spec that installs the engine into a checkout that does not
      # bundle it: the same version as this dashboard's, or the git revision
      # or path this dashboard bundles it from (see .engine_gems).
      #
      # @param apply [String] "always", or "without_engine" for only a
      #   checkout without the engine
      # @raise [Invalid] for options no spec can hold, and when the engine's
      #   gems come from a git URL that carries credentials
      #
      # @param steps [Array<Hash>] more steps, run after db_prepare
      def bootstrap(apply: "always", start_url: "/", keep_on_failure: false, env: {}, secrets: {}, timeout: BOOTSTRAP_TIMEOUT,
        engine: engine_gems, steps: [])
        new(
          "kind" => "bootstrap",
          "apply" => apply,
          "preflight" => true,
          "steps" => bootstrap_steps(engine) + steps,
          "env" => env,
          "secrets" => secrets,
          "manifest" => { "command" => "bin/rails action_agent:sandbox:manifest", "timeout" => 300 },
          "start" => { "command" => "bin/rails server -b 127.0.0.1 -p $PORT", "timeout" => 300 },
          "start_url" => start_url,
          "keep_on_failure" => keep_on_failure,
          "timeout" => timeout,
          "engine" => engine
        )
      end

      # The spec for a checkout that bundles the engine already because a
      # bootstrap's changes were published to its branch: the bootstrap's
      # steps without the INSTALL_STEPS, whatever the checkout's
      # sandbox.yml says.
      #
      # @param steps [Array<Hash>] more steps, run after db_prepare
      def installed(start_url: "/", keep_on_failure: false, env: {}, secrets: {}, steps: [])
        new(
          "kind" => "custom",
          "apply" => "always",
          "steps" => [ step("bundle_install", "bundle install", 900), *asset_steps, step("db_prepare", "bin/rails db:prepare", 900),
                       *steps ],
          "env" => env,
          "secrets" => secrets,
          "manifest" => { "command" => "bin/rails action_agent:sandbox:manifest", "timeout" => 300 },
          "start" => { "command" => "bin/rails server -b 127.0.0.1 -p $PORT", "timeout" => 300 },
          "start_url" => start_url,
          "keep_on_failure" => keep_on_failure,
          "timeout" => BOOTSTRAP_TIMEOUT
        )
      end

      # The step that writes app/agent_tools/<model>_tools.rb for each model
      # in +choices+ with `active_agent:schema_tools`, exposing only the
      # columns chosen, or nil when nothing is chosen.
      #
      #   [{ "model" => "Reservation", "filterable" => ["status"], "returns" => ["status", "starts_at"] }]
      #
      # @raise [Invalid] for a model or column name that is not one, or more
      #   than MAX_SCHEMA_TOOL_MODELS models
      def schema_tools_step(choices)
        choices = Array(choices)
        return nil if choices.empty?
        raise Invalid, "at most #{MAX_SCHEMA_TOOL_MODELS} models can have schema tools" if choices.size > MAX_SCHEMA_TOOL_MODELS

        commands = choices.map do |choice|
          choice = choice.to_h.stringify_keys
          model = choice["model"].to_s
          raise Invalid, "#{model.truncate(60).inspect} is not a model name" unless MODEL_NAME.match?(model)

          words = [ "bin/rails", "generate", "active_agent:schema_tools", model, "--force" ]
          %w[filterable returns].each do |option|
            columns = schema_tool_columns(choice[option], model, option)
            words.push("--#{option}", *columns) if columns.any?
          end
          words.shelljoin
        end
        step("schema_tools", commands.join(" && "), 900)
      end

      # A sandbox request's boot options, checked and in the shape a job
      # argument carries them. They hold no secrets.
      #
      # @param bootstrap [String, Boolean, nil] "auto" (the default), "always"
      #   or "never"; true and false read as "always" and "never"
      # @param start_url [String, nil] a path on the app, "/" when blank
      # @param keep_on_failure [Boolean, String, nil]
      # @return [Hash] { "bootstrap" =>, "start_url" =>, "keep_on_failure" => }
      # @raise [Invalid]
      def request_options(bootstrap: nil, start_url: nil, keep_on_failure: nil)
        mode =
          case bootstrap
          when nil, "" then "auto"
          when true, "true" then "always"
          when false, "false" then "never"
          else bootstrap.to_s
          end
        raise Invalid, "`bootstrap` must be one of #{BOOTSTRAP_MODES.join(", ")}" unless BOOTSTRAP_MODES.include?(mode)

        url = start_url.presence || "/"
        raise Invalid, "`start_url` must be a path on the app, such as /" unless url.is_a?(String) && start_url_path?(url)

        { "bootstrap" => mode, "start_url" => url, "keep_on_failure" => ActiveModel::Type::Boolean.new.cast(keep_on_failure) == true }
      end

      # The spec .request_options ask for: nil for "never", and for "auto" a
      # bootstrap that applies only to a checkout without the engine.
      #
      # @raise [Invalid] as .bootstrap does
      def for_request(options)
        options = request_options(**options.to_h.symbolize_keys.slice(:bootstrap, :start_url, :keep_on_failure))
        return nil if options["bootstrap"] == "never"

        bootstrap(apply: options["bootstrap"] == "always" ? "always" : "without_engine",
          start_url: options["start_url"], keep_on_failure: options["keep_on_failure"])
      end

      def start_url_path?(url)
        url.start_with?("/") && !url.start_with?("//") && url.length <= MAX_START_URL_LENGTH && url.match?(/\A[[:graph:]]+\z/)
      end

      # Where a bootstrap takes activeagent and actionagent from: wherever
      # this dashboard's own bundle has them. A gem from rubygems.org is
      # added at this process's version (`~>`), one from git at the same
      # revision, and one from a path at the same path, which only a backend
      # on this machine can reach.
      #
      #   { "activeagent" => { "source" => "rubygems", "version" => "1.9.0" },
      #     "actionagent" => { "source" => "path", "path" => "/src/activeagent/actionagent" } }
      #
      # @param locked_gems [Bundler::LockfileParser, nil] the dashboard's lock;
      #   nil when it runs without Bundler
      # @raise [Invalid] for a git URL with credentials in it, which would end
      #   up in the checkout's Gemfile and logs
      def engine_gems(locked_gems = default_locked_gems)
        specs = locked_gems.respond_to?(:specs) ? locked_gems.specs.to_a : []
        { "activeagent" => ActiveAgent::VERSION, "actionagent" => ActionAgent::VERSION }.to_h do |name, version|
          [ name, gem_source(name, specs.find { |spec| spec.name == name }&.source, version) ]
        end
      end

      private

      def default_locked_gems
        defined?(::Bundler) ? ::Bundler.locked_gems : nil
      rescue StandardError
        nil
      end

      def gem_source(name, source, version)
        if defined?(::Bundler::Source::Git) && source.is_a?(::Bundler::Source::Git)
          uri = source.uri.to_s
          if CREDENTIALED_URL.match?(uri)
            raise Invalid, "the dashboard bundles #{name} from a git URL with credentials in it, which a sandbox " \
              "would write into the checkout's Gemfile"
          end

          { "source" => "git", "uri" => uri, "ref" => source.revision.to_s }
        elsif defined?(::Bundler::Source::Path) && source.is_a?(::Bundler::Source::Path)
          { "source" => "path", "path" => source.expanded_original_path.to_s }
        else
          { "source" => "rubygems", "version" => version }
        end
      end

      def bootstrap_steps(engine)
        framework = engine.fetch("activeagent")
        steps = [
          step("bundle_config", "bundle config set --local frozen false", 60),
          step("bundle_install", "bundle install", 900)
        ]
        # From rubygems.org the engine brings the framework with it. From git
        # or a path the framework must come from the same place.
        if framework["source"] != "rubygems"
          steps << step("add_framework", add_gem("activeagent", framework, skip_install: true), 300, unless_locked: "activeagent")
        end
        steps << step("add_engine", add_gem("actionagent", engine.fetch("actionagent")), 900, unless_locked: "actionagent")
        # --skip: run with no terminal, Thor would take end of input as
        # "overwrite" for every file that already exists.
        steps << step("install_framework", "bin/rails generate active_agent:install --skip", 300, unless_locked: "activeagent")
        steps << step("install_engine", "bin/rails generate action_agent:install --skip", 300, unless_locked: "actionagent")
        steps.concat(asset_steps)
        steps << step("db_prepare", "bin/rails db:prepare", 900)
      end

      def asset_steps
        ASSET_TASKS.map { |task| step(task.tr(":", "_"), "bin/rails #{task}", 600, if_task: task) }
      end

      def schema_tool_columns(value, model, option)
        columns = Array(value).map(&:to_s).uniq
        raise Invalid, "#{model} has more than #{MAX_SCHEMA_TOOL_COLUMNS} #{option} columns" if columns.size > MAX_SCHEMA_TOOL_COLUMNS

        columns.each do |column|
          raise Invalid, "#{column.truncate(60).inspect} is not a column name" unless COLUMN_NAME.match?(column)
          if SandboxManifest::SECRET_COLUMNS.match?(column)
            raise Invalid, "#{model}.#{column} looks like it holds a secret, so no tool may read it"
          end
        end
        columns
      end

      def step(name, command, timeout, **conditions)
        { "name" => name, "command" => command, "timeout" => timeout, **conditions.transform_keys(&:to_s) }
      end

      def add_gem(name, source, skip_install: false)
        words = [ "bundle add #{name}" ]
        words <<
          case source["source"]
          when "git" then "--git #{Shellwords.escape(source.fetch("uri"))} --ref #{Shellwords.escape(source.fetch("ref"))}"
          when "path" then "--path #{Shellwords.escape(source.fetch("path"))}"
          else %(--version "~> #{source.fetch("version")}")
          end
        words << "--skip-install" if skip_install
        words.join(" ")
      end
    end

    # @param data [Hash] #to_h's shape
    # @raise [Invalid]
    def initialize(data)
      raise Invalid, "a boot spec is a Hash, not #{data.class}" unless data.is_a?(Hash)

      data = data.deep_stringify_keys
      @kind = one_of(data.fetch("kind", "custom"), KINDS, "kind")
      @apply = one_of(data.fetch("apply", "always"), APPLY_MODES, "apply")
      @preflight = data["preflight"] == true
      @steps = parse_steps(data["steps"])
      @env = parse_env(data["env"], "env")
      @secrets = parse_env(data["secrets"], "secrets")
      refused = @secrets.keys.grep(REFUSED_SECRET_NAME)
      raise Invalid, "secrets may not set #{refused.join(", ")}" if refused.any?

      @secret_names = (Array(data["secret_names"]).map(&:to_s) | @secrets.keys).freeze
      @manifest = parse_command(data["manifest"], "manifest", "bin/rails action_agent:sandbox:manifest")
      @start = parse_command(data["start"], "start", "bin/rails server -b 127.0.0.1 -p $PORT")
      @start_url = parse_start_url(data.fetch("start_url", "/"))
      @keep_on_failure = data["keep_on_failure"] == true
      @timeout = parse_timeout(data.fetch("timeout", @kind == "bootstrap" ? BOOTSTRAP_TIMEOUT : DEFAULT_STEP_TIMEOUT), "timeout")
      if @kind == "bootstrap" && @timeout < BOOTSTRAP_TIMEOUT
        raise Invalid, "a bootstrap boot needs a timeout of at least #{BOOTSTRAP_TIMEOUT}s, not #{@timeout}s"
      end

      @engine = data["engine"].is_a?(Hash) ? data["engine"] : nil
      freeze
    end

    def preflight?
      @preflight
    end

    def keep_on_failure?
      @keep_on_failure
    end

    def bootstrap?
      @kind == "bootstrap"
    end

    # Whether the spec applies only to a checkout without the engine.
    def without_engine_only?
      @apply == "without_engine"
    end

    # Secret names the spec names without carrying their values: a
    # #redacted spec read back.
    def missing_secrets
      @secret_names - @secrets.keys
    end

    # The environment the steps, manifest and start add.
    def step_environment
      @env.merge(@secrets)
    end

    # What scrubbing masks.
    def secret_values
      @secrets.values
    end

    # The whole spec, secrets included: for a backend, in memory.
    def to_h
      {
        "kind" => @kind, "apply" => @apply, "preflight" => @preflight,
        "steps" => @steps.map(&:dup), "env" => @env.dup, "secrets" => @secrets.dup,
        "manifest" => @manifest.dup, "start" => @start.dup, "start_url" => @start_url,
        "keep_on_failure" => @keep_on_failure, "timeout" => @timeout, "engine" => @engine
      }.compact
    end

    # #to_h without the secrets' values: what may be stored or logged.
    def redacted
      to_h.except("secrets").merge("secret_names" => @secret_names.dup)
    end

    private

    def one_of(value, allowed, key)
      value = value.to_s
      raise Invalid, "`#{key}` must be one of #{allowed.join(", ")}, not #{value.inspect}" unless allowed.include?(value)

      value
    end

    def parse_steps(value)
      return [].freeze if value.nil?
      raise Invalid, "`steps` must be a list" unless value.is_a?(Array)
      raise Invalid, "`steps` may hold at most #{MAX_STEPS} steps" if value.size > MAX_STEPS

      steps = value.map { |entry| parse_step(entry) }
      duplicate = steps.map { |step| step["name"] }.tally.find { |_name, count| count > 1 }&.first
      raise Invalid, "step names must be unique (#{duplicate} is not)" if duplicate

      steps.each(&:freeze).freeze
    end

    def parse_step(entry)
      raise Invalid, "each step must be a mapping" unless entry.is_a?(Hash)

      name = entry["name"].to_s
      unless STEP_NAME.match?(name) && !RESERVED_STEP_NAMES.include?(name)
        raise Invalid, "#{entry["name"].inspect} is not a step name (lowercase, digits and _; not #{RESERVED_STEP_NAMES.join(", ")})"
      end

      step = { "name" => name, "command" => command!(entry["command"], "step #{name}"),
               "timeout" => parse_timeout(entry.fetch("timeout", DEFAULT_STEP_TIMEOUT), "step #{name}'s timeout") }
      if entry.key?("unless_locked")
        raise Invalid, "step #{name}'s unless_locked must name a gem" unless GEM_NAME.match?(entry["unless_locked"].to_s)

        step["unless_locked"] = entry["unless_locked"].to_s
      end
      if entry.key?("if_task")
        raise Invalid, "step #{name}'s if_task must name a Rake task" unless TASK_NAME.match?(entry["if_task"].to_s)

        step["if_task"] = entry["if_task"].to_s
      end
      step
    end

    def parse_command(value, key, default)
      return { "command" => default, "timeout" => DEFAULT_STEP_TIMEOUT }.freeze if value.nil?

      value = { "command" => value } if value.is_a?(String)
      raise Invalid, "`#{key}` must be a command" unless value.is_a?(Hash)

      { "command" => command!(value["command"], key),
        "timeout" => parse_timeout(value.fetch("timeout", DEFAULT_STEP_TIMEOUT), "#{key}'s timeout") }.freeze
    end

    def command!(value, what)
      unless value.is_a?(String) && value.strip.present? && value.length <= MAX_COMMAND_LENGTH && !value.include?("\0")
        raise Invalid, "#{what} needs a command (a string of at most #{MAX_COMMAND_LENGTH} characters)"
      end

      value
    end

    def parse_timeout(value, what)
      seconds = Integer(value, exception: false) if value.is_a?(Integer) || value.is_a?(String)
      raise Invalid, "#{what} must be a number of seconds from 1 to #{MAX_TIMEOUT}" unless seconds&.between?(1, MAX_TIMEOUT)

      seconds
    end

    def parse_env(value, key)
      return {}.freeze if value.nil?
      raise Invalid, "`#{key}` must map variable names to strings" unless value.is_a?(Hash)

      value.to_h do |name, setting|
        scalar = setting.is_a?(String) || setting.is_a?(Numeric) || setting == true || setting == false
        unless scalar && ENV_NAME.match?(name.to_s) && !setting.to_s.include?("\0")
          raise Invalid, "`#{key}` must map variable names to strings (#{name.inspect} does not)"
        end

        [ name.to_s, setting.to_s ]
      end.freeze
    end

    def parse_start_url(value)
      url = value.to_s
      raise Invalid, "`start_url` must be a path on the app, such as /" unless self.class.start_url_path?(url)

      url
    end
  end
end
