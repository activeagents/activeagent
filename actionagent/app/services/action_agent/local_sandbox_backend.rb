# frozen_string_literal: true

require "io/wait"
require "net/http"
require "open3"
require "socket"
require "tmpdir"

module ActionAgent
  # Boots app_runtime checkouts as child processes of the dashboard itself,
  # with no containers: the sandbox backend for a developer's own machine
  # (see ActionAgent.local_sandboxes_enabled?). Each sandbox is a workspace
  # under ActionAgent.local_sandbox_root:
  #
  #   <session_id>/
  #     app/          the checkout
  #     runtime.json  the manifest the checkout wrote (see SandboxManifest)
  #     state.json    { pid, port, started_at, code_sessions: { "<id>" => pid } },
  #                   plus the commit checked out, when each recorded process
  #                   started, cancels that found nothing to stop yet, and
  #                   whether a terminate is under way
  #     logs/         checkout, setup, manifest, server and claude-<id> logs
  #     claude/       CLAUDE_CONFIG_DIR for Claude Code sessions
  #
  # The orchestrator builds a new backend for every call, and the dashboard
  # may restart while a sandbox runs, so whatever a later call needs lives in
  # state.json rather than in instance variables. Calls race each other
  # through that file (a cancel or a terminate while Claude Code starts), so
  # it is only ever changed under an exclusive lock.
  #
  # How a checkout boots is up to its .activeagents/sandbox.yml (see Config).
  # Every process starts from a sanitized copy of the dashboard's environment
  # (see .sanitized_environment), so a checkout never sees the dashboard's
  # database or secrets. The GitHub token reaches only the fetch, and the
  # Claude Code credential only Claude Code.
  class LocalSandboxBackend
    class Error < RuntimeError; end

    HANDLE_PREFIX = "local-"
    # Session ids are generated UUIDs; anything else is refused before it can
    # name a path outside the sandbox root.
    SESSION_ID = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/
    # Set in every process a sandbox starts. Where state.json has no start
    # time for a recorded pid, this is how it is told apart from an
    # unrelated process that later reused it.
    SESSION_ID_ENV = "ACTION_AGENT_SANDBOX_SESSION_ID"
    COMMIT_ID = /\A\h{40}(?:\h{24})?\z/

    # A GET on the MCP path answers 405 once the engine is mounted and
    # serving; 401 and 200 also mean something is up and answering there.
    READY_STATUSES = [ 405, 401, 200 ].freeze
    POLL_INTERVAL = 0.25
    # Between SIGTERM and SIGKILL when stopping a sandbox.
    STOP_GRACE = 10
    LOG_TAIL_LINES = 20
    LOG_TAIL_BYTES = 64 * 1024

    # Bounds on the git commands run in a checkout (rev-parse after the
    # fetch, add and diff after a session) and on the diff a Claude Code
    # session hands back. The diff limit is above CodeSession's own, so its
    # truncation notice still shows.
    GIT_TIMEOUT = 60
    MAX_DIFF_BYTES = 1_000_000
    # How long a cancel that found no Claude Code process is remembered. The
    # session it names starts within seconds of being marked running, or
    # never; this only keeps old ones from piling up in state.json.
    CANCEL_MEMORY = 3600
    # One stream-json line can carry a whole file; past this it is cut.
    MAX_EVENT_LINE_BYTES = 8 * 1024 * 1024
    # How long output may keep arriving after Claude Code itself exited.
    OUTPUT_DRAIN_GRACE = 2
    HELP_TIMEOUT = 15
    MODEL_NAME = %r{\A[A-Za-z0-9][A-Za-z0-9._:/@\[\]-]{0,127}\z}

    # Never inherited from the dashboard: its database, its keys, and the
    # Ruby/Bundler setup of its own bundle (a checkout has its own Gemfile).
    DROPPED_VARIABLES = %w[
      DATABASE_URL REDIS_URL SECRET_KEY_BASE RAILS_MASTER_KEY RAILS_ENV RACK_ENV PORT
      BUNDLE_GEMFILE RUBYOPT RUBYLIB
    ].freeze
    DROPPED_VARIABLE_PATTERN = /
      _DATABASE_URL\z | \AACTIVE_RECORD_ENCRYPTION_ | \ABUNDLER?_ |
      # Where git finds a repository. Set when the dashboard runs under a git
      # hook, and they would point the checkout's git at the dashboard's own.
      \AGIT_(?:DIR|WORK_TREE|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|COMMON_DIR|
        NAMESPACE|PREFIX|QUARANTINE_PATH|CONFIG|CONFIG_PARAMETERS|CONFIG_COUNT|CONFIG_KEY_\d+|CONFIG_VALUE_\d+)\z |
      # The dashboard's own model-provider and Claude Code settings. A
      # developer often runs the dashboard from inside Claude Code, which
      # exports CLAUDECODE, CLAUDE_CODE_* (its own session id among them) and
      # ANTHROPIC_BASE_URL; a session inheriting those joins the developer's
      # session, and a base URL redirects the owner's credential. A session
      # gets exactly the Claude Code variables the backend sets.
      \A(?:ANTHROPIC|CLAUDE|OPENAI|OPEN_AI|OPENROUTER|OPEN_ROUTER|OLLAMA)(?:_|\z) | \ACLAUDECODE\z
    /x
    SECRET_VARIABLE = /
      SECRET | TOKEN | PASSWORD | PASSWD | PASSPHRASE | API_KEY | APIKEY | PRIVATE_KEY | CREDENTIAL | ACCESS_KEY |
      # DB_PASS, MYSQL_PWD, LOCKBOX_MASTER_KEY, SENTRY_DSN, SLACK_WEBHOOK_URL, GITHUB_PAT
      (?:\A|_)PASS\z | (?:\A|_)PWD\z | _KEY\z | DSN\z | WEBHOOK | (?:\A|_)PAT\z
    /xi
    # A URL carrying a password (redis://:secret@host), whatever its name.
    CREDENTIALED_URL = %r{\A[a-z][a-z0-9+.-]*://[^/\s@]*:[^/\s@]+@}i

    # Fetches the checkout with the token in this process's environment only.
    # Git gets the credential through GIT_CONFIG_* for the one fetch: never in
    # argv (which `ps` shows every user) and never in .git/config (which the
    # checked-out app and Claude Code can read). No credential helper is asked,
    # so the fetch uses this token or nothing.
    CHECKOUT_SCRIPT = <<~'SH'
      set -eu
      git init -q "$APP_DIR"
      cd "$APP_DIR"
      git remote add origin "$CHECKOUT_URL"
      header=""
      if [ -n "${CHECKOUT_TOKEN:-}" ]; then
        header="Authorization: Basic $(printf '%s:%s' "$CHECKOUT_USERNAME" "$CHECKOUT_TOKEN" | base64 | tr -d '\n')"
      fi
      unset CHECKOUT_TOKEN
      GIT_CONFIG_COUNT=2 \
        GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= \
        GIT_CONFIG_KEY_1=http.extraHeader GIT_CONFIG_VALUE_1="$header" \
        git fetch -q --depth 1 origin "$CHECKOUT_REF"
      git checkout -q --detach FETCH_HEAD
    SH

    # .activeagents/sandbox.yml, the checkout's say in how it boots. Every key
    # is optional: a Rails app that mounts this engine boots without the file.
    #
    #   env:      extra environment for setup, manifest and server
    #   setup:    commands run once after checkout, in order
    #   manifest: writes the manifest JSON to $ACTION_AGENT_SANDBOX_MANIFEST
    #   start:    serves on 127.0.0.1:$PORT and keeps running
    #
    # Unknown keys are ignored, so a newer file still boots here.
    class Config
      PATH = File.join(".activeagents", "sandbox.yml")
      DEFAULT_SETUP = [ "bundle install", "bin/rails db:prepare" ].freeze
      DEFAULT_MANIFEST = "bin/rails action_agent:sandbox:manifest"
      DEFAULT_START = "bin/rails server -b 127.0.0.1 -p $PORT"
      ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      attr_reader :env, :setup, :manifest, :start

      def self.load(app_dir)
        file = Pathname(app_dir).join(PATH)
        data = file.file? ? YAML.safe_load(file.read, aliases: false) : nil
        data = {} if data.nil?
        invalid!("it must be a mapping of settings") unless data.is_a?(Hash)

        new(
          env: parse_env(data["env"]),
          setup: parse_setup(data["setup"]),
          manifest: parse_command(data, "manifest", DEFAULT_MANIFEST),
          start: parse_command(data, "start", DEFAULT_START)
        )
      rescue Psych::Exception => e
        invalid!("it is not valid YAML (#{e.message.truncate(200)})")
      end

      def self.parse_env(value)
        return {} if value.nil?
        invalid!("`env` must be a mapping of names to strings") unless value.is_a?(Hash)

        value.to_h do |name, setting|
          scalar = case setting
          when String, Integer, Float, true, false then true
          else false
          end
          unless scalar && name.is_a?(String) && ENV_NAME.match?(name)
            invalid!("`env` must map variable names to strings (#{name.inspect} does not)")
          end

          [ name, setting.to_s ]
        end
      end

      def self.parse_setup(value)
        return DEFAULT_SETUP if value.nil?

        commands = value.is_a?(String) ? [ value ] : value
        unless commands.is_a?(Array) && commands.all? { |command| command.is_a?(String) && command.present? }
          invalid!("`setup` must be a list of commands")
        end
        commands
      end

      def self.parse_command(data, key, default)
        return default if data[key].nil?
        invalid!("`#{key}` must be a command") unless data[key].is_a?(String) && data[key].present?

        data[key]
      end

      def self.invalid!(problem)
        raise Error, "Sandbox configuration failed: #{PATH} is malformed: #{problem}"
      end

      def initialize(env:, setup:, manifest:, start:)
        @env = env
        @setup = setup
        @manifest = manifest
        @start = start
      end
    end

    class << self
      # The environment every sandbox process starts from: the dashboard's
      # own, as it was before Bundler set it up, minus the dashboard's
      # database, keys and anything named like a credential. Processes are
      # spawned with exactly this (plus what the step adds) and
      # unsetenv_others, so nothing else leaks through.
      #
      # Bundler.unbundled_env is what Bundler.with_unbundled_env swaps into
      # ENV; reading it directly leaves the process-wide ENV alone, which other
      # threads of the dashboard are reading at the same time.
      #
      # @param source [Hash, nil] the environment to sanitize (for tests)
      # @return [Hash{String => String}]
      def sanitized_environment(source = nil)
        source ||= defined?(::Bundler) ? ::Bundler.unbundled_env : ENV.to_h

        source.each_with_object({}) do |(name, value), env|
          name = name.to_s
          next if value.nil? || DROPPED_VARIABLES.include?(name)
          next if DROPPED_VARIABLE_PATTERN.match?(name) || SECRET_VARIABLE.match?(name)
          next if CREDENTIALED_URL.match?(value.to_s)

          env[name] = value.to_s
        end
      end

      # Whether +command+ (a Claude Code executable) takes
      # `--permission-prompts`, read from its --help once per process: the
      # answer only changes when the CLI is upgraded. The block runs the help
      # and returns its output, or nil when it could not run (which is not
      # remembered, so installing the CLI later is noticed).
      def permission_prompts_supported?(command)
        @cli_support_lock.synchronize do
          return @cli_support[command] if @cli_support.key?(command)

          help = yield
          help.nil? ? false : (@cli_support[command] = help.include?("--permission-prompts"))
        end
      end
    end

    @cli_support = {}
    @cli_support_lock = Mutex.new

    # Clones the session's checkout, boots it as sandbox.yml says, and waits
    # until its MCP facade answers.
    #
    # @return [Hash] the handle (container_name), url, mcp_url and mcp_token
    def create_sandbox(session, instance_tier: nil)
      ensure_enabled!
      unless session.app_runtime?
        raise Error, "The local sandbox backend only boots app_runtime checkouts, not #{session.sandbox_type} sandboxes"
      end

      spec = session.checkout_spec
      raise Error, "Sandbox #{session.session_id} has no checkout to boot (is GitHub still connected?)" if spec.blank?

      session_id = session_id!(session.session_id)
      # A retried provision (say the dashboard restarted mid-boot) starts
      # clean rather than on a half-built checkout next to a stray server.
      discard(session_id)
      boot(session_id, spec, [ spec[:token], *session.runtime_environment.values ])
    end

    # Stops the sandbox's server and any Claude Code sessions it recorded,
    # then removes its workspace. Returns true, also when there was nothing
    # to stop.
    # A sandbox's handle follows from its session id, so one whose boot was
    # never recorded can still be found and stopped.
    def handle_for(session)
      "local-#{session.session_id}"
    end

    def terminate(handle)
      session_id = session_id_from(handle)
      discard(session_id) if session_id
      true
    end

    # @return [Hash] { status: "running" | "stopped" | "not_found", pid:, port: }
    def status(handle)
      session_id = session_id_from(handle)
      workspace = session_id && workspace_for(session_id)
      return { status: "not_found", pid: nil, port: nil } unless workspace&.directory?

      state = read_state(workspace)
      pid = state["pid"]
      running = recorded_group?(pid, session_id, state) && group_alive?(pid)
      { status: running ? "running" : "stopped", pid: pid, port: state["port"] }
    end

    # One entry per workspace on disk.
    def list_sandboxes
      root = ActionAgent.local_sandbox_root
      return [] unless root.directory?

      root.children.select(&:directory?).filter_map do |dir|
        session_id = dir.basename.to_s
        next unless SESSION_ID.match?(session_id)

        handle = "#{HANDLE_PREFIX}#{session_id}"
        status(handle).merge(container_name: handle, session_id: session_id)
      end
    end

    # The engine reaps expired sandboxes itself (SandboxCleanupJob), one
    # terminate at a time.
    def cleanup_expired
      0
    end

    # Runs Claude Code headless in the sandbox's checkout, yielding each
    # stream-json event (a Hash, already scrubbed of the sandbox's secrets)
    # as it arrives.
    #
    # @return [Hash] { exit_status: Integer, diff: String, stderr_tail: String }
    def run_code_session(sandbox, code_session, &on_event)
      ensure_enabled!
      session_id = session_id!(sandbox.session_id)
      workspace = workspace_for(session_id)
      app = workspace.join("app")
      raise Error, "Sandbox #{session_id} has no local checkout: start the sandbox again" unless app.directory?

      credentials = sandbox.runtime_environment.to_h
      raise Error, "Claude Code is not connected: Connect Claude Code in Settings → Integrations" if credentials.empty?

      secrets = sandbox_secrets(sandbox, credentials)
      argv = claude_argv(code_session)
      env = self.class.sanitized_environment
        .merge(credentials.to_h { |name, value| [ name.to_s, value.to_s ] })
        .merge(
          "CLAUDE_CONFIG_DIR" => workspace.join("claude").to_s,
          SESSION_ID_ENV => session_id,
          "DISABLE_AUTOUPDATER" => "1",
          "DISABLE_TELEMETRY" => "1",
          "DISABLE_ERROR_REPORTING" => "1",
          "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"
        )
      FileUtils.mkdir_p(workspace.join("claude"), mode: 0o700)

      run_claude(workspace, code_session, argv, env, secrets, &on_event)
    end

    # Stops a running Claude Code session: SIGTERM to its process group. The
    # run_code_session that started it then finishes with what it has.
    #
    # The session is marked running before Claude Code starts (the --help
    # probe alone can take seconds), so a cancel can find no process yet.
    # It is then remembered in state.json, under the lock run_code_session
    # records its process with, and the session stops as soon as it starts
    # (see #record_code_session), or never starts at all.
    def cancel_code_session(sandbox, code_session)
      session_id = session_id!(sandbox.session_id)
      workspace = workspace_for(session_id)
      return true unless workspace.directory?

      key = code_session.id.to_s
      update_state(workspace, create: false) do |state|
        pid = state_hash(state, "code_sessions")[key]
        if pid
          signal_group(pid, "TERM") if recorded_group?(pid, session_id, state)
        else
          cancels = state_hash(state, "cancelled_code_sessions")
          cancels.delete_if { |_id, at| !at.is_a?(Numeric) || at < Time.now.to_f - CANCEL_MEMORY }
          cancels[key] = Time.now.to_i
        end
      end
      true
    rescue Errno::ENOENT
      # No state.json, so the sandbox never booted, or it was removed
      # meanwhile: either way no Claude Code session runs there.
      true
    end

    private

    def ensure_enabled!
      return if ActionAgent.local_sandboxes_enabled?

      raise Error, "Local sandboxes are disabled. They run checkouts and Claude Code as processes on this machine; " \
        "set ActionAgent.local_sandboxes_enabled = true to allow them"
    end

    # --- Boot -------------------------------------------------------------

    def boot(session_id, spec, secrets)
      workspace = workspace_for(session_id)
      deadline = deadline_after(ActionAgent.local_sandbox_boot_timeout)
      booted = false
      server_pid = nil

      prepare_workspace(workspace)
      checkout!(workspace, spec, secrets, deadline)

      app = workspace.join("app")
      config = Config.load(app)
      env = self.class.sanitized_environment.merge(config.env).merge(
        # Merged after the file's env, so a checkout cannot move them.
        SandboxManifest::PATH_ENV => workspace.join("runtime.json").to_s,
        SESSION_ID_ENV => session_id
      )

      config.setup.each do |command|
        run_step!(workspace, "setup", command, env: env, chdir: app, deadline: deadline, secrets: secrets)
      end

      # Picked after setup, which can take minutes, so the port is still
      # free when the server binds it.
      port = free_port
      env = env.merge("PORT" => port.to_s)
      manifest = run_manifest!(workspace, config, env, deadline, secrets)

      server_pid, waiter = start_server(workspace, config, env, port)
      wait_until_ready!(workspace, port, manifest["mcp_path"], waiter, deadline, secrets)
      booted = true

      {
        container_name: "#{HANDLE_PREFIX}#{session_id}",
        url: "http://127.0.0.1:#{port}",
        container_ip: "127.0.0.1",
        mcp_url: "http://127.0.0.1:#{port}#{manifest["mcp_path"]}",
        mcp_token: manifest["mcp_token"],
        created_at: Time.current
      }
    rescue Error
      raise
    rescue StandardError => e
      raise Error, SecretScrubber.scrub("Sandbox boot failed: #{e.class.name}: #{e.message}", secrets)
    ensure
      # A failed boot leaves nothing running and nothing on disk: no handle
      # was reported, so nothing would ever reap it. The error carries the
      # failing step's log tail.
      unless booted
        stop_groups([ server_pid ].compact)
        remove_workspace(workspace) if workspace
      end
    end

    def prepare_workspace(workspace)
      FileUtils.mkdir_p(ActionAgent.local_sandbox_root)
      # Owner-only: the checkout and runtime.json hold the app's own secrets.
      FileUtils.mkdir_p(workspace, mode: 0o700)
      FileUtils.mkdir_p(workspace.join("logs"), mode: 0o700)
      FileUtils.mkdir_p(workspace.join("claude"), mode: 0o700)
    end

    def checkout!(workspace, spec, secrets, deadline)
      env = self.class.sanitized_environment.merge(
        "APP_DIR" => workspace.join("app").to_s,
        "CHECKOUT_URL" => spec[:clone_url].to_s,
        "CHECKOUT_REF" => spec[:ref].presence || "HEAD",
        "CHECKOUT_USERNAME" => spec[:username].presence || "x-access-token",
        "CHECKOUT_TOKEN" => spec[:token].to_s,
        # Fail rather than prompt when the token is refused.
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_ASKPASS" => ""
      )
      run_step!(workspace, "checkout", CHECKOUT_SCRIPT, env: env, chdir: workspace, deadline: deadline, secrets: secrets,
        label: "git fetch #{spec[:clone_url]} #{spec[:ref]}")
      record_checkout_commit(workspace)
    end

    # What a Claude Code session's diff is taken against, so it shows the
    # session's changes even where the session committed them, or staged a
    # removal, itself. Without it the diff falls back to HEAD.
    def record_checkout_commit(workspace)
      argv = [ *git_command(workspace.join("app")), "rev-parse", "--verify", "HEAD^{commit}" ]
      output, status = capture(self.class.sanitized_environment, argv, chdir: workspace, limit: 1024, timeout: GIT_TIMEOUT)
      commit = output.strip
      update_state(workspace) { |state| state["checkout_commit"] = commit } if status&.success? && COMMIT_ID.match?(commit)
    end

    def run_manifest!(workspace, config, env, deadline, secrets)
      path = workspace.join("runtime.json")
      FileUtils.rm_f(path)
      run_step!(workspace, "manifest", config.manifest, env: env, chdir: workspace.join("app"), deadline: deadline, secrets: secrets)

      log = log_path(workspace, "manifest")
      fail_step!("manifest", "`#{config.manifest}` wrote nothing to $#{SandboxManifest::PATH_ENV}", log, secrets) unless path.file?

      manifest = SandboxManifest.parse(path.read)
      URI.parse("http://127.0.0.1#{manifest["mcp_path"]}")
      manifest
    rescue SandboxManifest::Error, URI::InvalidURIError => e
      fail_step!("manifest", e.message, log_path(workspace, "manifest"), secrets)
    end

    # Runs one boot command to completion in its own process group, with its
    # output in logs/<step>.log. Anything it left running in that group is
    # stopped too: a setup command is not a way to start services the
    # sandbox never records (that is what `start` is for).
    def run_step!(workspace, step, command, env:, chdir:, deadline:, secrets:, label: command)
      log = log_path(workspace, step)
      File.open(log, "a") { |file| file.puts("$ #{label}") }

      pid = spawn_group(env, "sh", "-c", command, chdir: chdir, in: File::NULL, out: [ log.to_s, "a" ], err: [ :child, :out ])
      waiter = Process.detach(pid)
      finished = waiter.join(time_left(deadline))
      stop_groups([ pid ], grace: finished ? 1 : STOP_GRACE)

      unless finished
        fail_step!(step, "`#{label}` did not finish within the boot timeout (#{ActionAgent.local_sandbox_boot_timeout}s)", log, secrets)
      end
      status = waiter.value
      fail_step!(step, "`#{label}` exited with #{describe(status)}", log, secrets) unless status.success?
    end

    def start_server(workspace, config, env, port)
      log = log_path(workspace, "server")
      File.open(log, "a") { |file| file.puts("$ #{config.start}") }

      pid = spawn_group(env, "sh", "-c", config.start,
        chdir: workspace.join("app"), in: File::NULL, out: [ log.to_s, "a" ], err: [ :child, :out ])
      # Reaped by this thread for as long as the dashboard lives; after a
      # restart the recorded pid is all that is left, hence state.json.
      waiter = Process.detach(pid)
      begin
        update_state(workspace) do |state|
          state.merge!("pid" => pid, "port" => port, "started_at" => Time.current.iso8601(3))
          state_hash(state, "code_sessions")
          record_process_start(state, pid)
        end
      rescue StandardError
        # Unrecorded, nothing could ever stop it later.
        stop_groups([ pid ])
        raise
      end
      [ pid, waiter ]
    end

    def wait_until_ready!(workspace, port, mcp_path, waiter, deadline, secrets)
      log = log_path(workspace, "server")
      uri = URI.parse("http://127.0.0.1:#{port}#{mcp_path}")
      last_status = nil

      loop do
        unless waiter.alive?
          fail_step!("server", "the server exited with #{describe(waiter.value)} before it answered on port #{port}", log, secrets)
        end

        status = probe(uri)
        return if READY_STATUSES.include?(status)

        last_status = status if status
        if monotonic >= deadline
          answered = last_status ? " (last answer: #{last_status})" : ""
          fail_step!("server", "the server did not answer #{mcp_path} on port #{port} within the boot timeout " \
            "(#{ActionAgent.local_sandbox_boot_timeout}s)#{answered}", log, secrets)
        end
        sleep POLL_INTERVAL
      end
    end

    # The HTTP status a GET on the MCP path answers with, or nil while
    # nothing answers.
    def probe(uri)
      # No proxy: the dashboard's HTTP(S)_PROXY does not know this loopback.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = 1
      http.read_timeout = 2
      http.start { |connection| connection.request(Net::HTTP::Get.new(uri, "Accept" => "application/json")).code.to_i }
    rescue SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse
      nil
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    # Raises the boot failure: the step, what went wrong, and the end of
    # that step's log, all scrubbed of the sandbox's secrets.
    def fail_step!(step, problem, log, secrets)
      tail = log_tail(log, secrets)
      message = "Sandbox #{step} failed: #{problem}"
      message += "\n--- last lines of logs/#{File.basename(log)} ---\n#{tail}" if tail.present?
      raise Error, SecretScrubber.scrub(message, secrets)
    end

    def log_tail(log, secrets)
      return "" unless File.file?(log)

      data = File.open(log, "rb") do |file|
        file.seek([ file.size - LOG_TAIL_BYTES, 0 ].max)
        file.read
      end
      lines = data.force_encoding(Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES)
      SecretScrubber.scrub(lines.map { |line| line.chomp.truncate(500) }.join("\n"), secrets)
    end

    # --- Claude Code --------------------------------------------------------

    def claude_argv(code_session)
      command = ActionAgent.claude_code_command.to_s
      argv = [
        command, "-p", "--output-format", "stream-json", "--verbose",
        "--permission-mode", ActionAgent.claude_code_permission_mode.to_s, "--no-session-persistence"
      ]
      # Nobody is there to answer a permission prompt: with this, anything
      # that would prompt is denied instead of stalling the session.
      argv += [ "--permission-prompts", "none" ] if permission_prompts_supported?(command)
      argv += [ "--max-turns", ActionAgent.claude_code_max_turns.to_i.to_s ] if ActionAgent.claude_code_max_turns.present?

      if (model = code_session.model.presence)
        # One argv entry, but one that must not read as a flag.
        raise Error, "#{model.inspect} is not a model name" unless MODEL_NAME.match?(model.to_s)

        argv += [ "--model", model.to_s ]
      end
      argv
    end

    def permission_prompts_supported?(command)
      self.class.permission_prompts_supported?(command) do
        output, status = capture(self.class.sanitized_environment, [ command, "--help" ],
          chdir: Dir.tmpdir, limit: 256 * 1024, timeout: HELP_TIMEOUT, err: [ :child, :out ])
        status ? output : nil
      rescue SystemCallError
        nil
      end
    end

    def run_claude(workspace, code_session, argv, env, secrets, &on_event)
      key = code_session.id.to_s
      log = log_path(workspace, "claude-#{key}")
      deadline = deadline_after(ActionAgent.claude_code_timeout)
      # Checked again once Claude Code is recorded; this saves starting it.
      state = read_state(workspace)
      refuse_stopped_session!(state, key)
      # A cancelled session frees its slot as soon as it is marked cancelled,
      # while its Claude Code may still be exiting (and diffing). Two in one
      # checkout would edit the same files.
      if other_session_running?(state, key, workspace.basename.to_s)
        raise Error, "The previous Claude Code session in this sandbox is still stopping; try again in a moment"
      end
      stdin_read, stdin_write = IO.pipe
      stdout_read, stdout_write = IO.pipe
      stderr_read, stderr_write = IO.pipe

      begin
        pid = spawn_group(env, *argv, chdir: workspace.join("app"), in: stdin_read, out: stdout_write, err: stderr_write)
      rescue SystemCallError => e
        raise Error, "Could not start Claude Code (#{argv.first}): #{e.message}"
      ensure
        [ stdin_read, stdout_write, stderr_write ].each(&:close)
      end
      waiter = Process.detach(pid)
      case record_code_session(workspace, key, pid)
      when :terminating
        # Stopped by the ensure below, before it had the prompt.
        raise Error, "The sandbox is being stopped, so Claude Code did not run"
      when :cancelled
        # Runs its course like any cancelled session: it ends on SIGTERM.
        signal_group(pid, "TERM")
      end

      # The prompt goes in on stdin, never argv, where `ps` would show it.
      writer = background { write_prompt(stdin_write, code_session.prompt) }
      stderr_tail = []
      reader = background { copy_stderr(stderr_read, log, secrets, stderr_tail) }

      finished = stream_events(stdout_read, waiter, deadline, secrets, &on_event) && waiter.join(time_left(deadline))
      unless finished
        stop_groups([ pid ])
        raise Error, "Claude Code did not finish within #{ActionAgent.claude_code_timeout}s and was stopped"
      end

      # Whatever the session left running in the background goes too.
      stop_groups([ pid ], grace: 1)
      reader.join(OUTPUT_DRAIN_GRACE)

      {
        exit_status: exit_code(waiter.value),
        diff: capture_diff(workspace, secrets),
        stderr_tail: SecretScrubber.scrub(stderr_tail.join("\n"), secrets)
      }
    ensure
      stop_groups([ pid ]) if pid
      [ stdin_write, stdout_read, stderr_read ].each { |io| io&.close unless io&.closed? }
      writer&.join(1)
      reader&.join(1)
      forget_code_session(workspace, key)
    end

    # Why a session must not start: a terminate under way, or a cancel that
    # came before there was a process to stop.
    def refuse_stopped_session!(state, key)
      raise Error, "The sandbox is being stopped, so Claude Code did not run" if state["terminating"]

      cancels = state["cancelled_code_sessions"]
      raise Error, "Claude Code session #{key} was cancelled before it started" if cancels.is_a?(Hash) && cancels.key?(key)
    end

    # Records Claude Code's pid (and start time) under the state.json lock,
    # the one cancel_code_session and terminate take too, so each either
    # finds this pid or left a mark here first. Returns :terminating when a
    # terminate is under way (or already removed the workspace), :cancelled
    # when a cancel came first, and nil otherwise.
    def other_session_running?(state, key, session_id)
      sessions = state["code_sessions"].is_a?(Hash) ? state["code_sessions"] : {}
      sessions.any? do |other, pid|
        other != key && pid.is_a?(Integer) && group_alive?(pid) && recorded_group?(pid, session_id, state)
      end
    end

    def record_code_session(workspace, key, pid)
      mark = nil
      update_state(workspace) do |state|
        state_hash(state, "code_sessions")[key] = pid
        record_process_start(state, pid)
        mark =
          if state["terminating"] then :terminating
          elsif state_hash(state, "cancelled_code_sessions").delete(key) then :cancelled
          end
      end
      mark
    rescue Errno::ENOENT
      :terminating
    end

    # Reads stream-json from +io+ until it closes, yielding each line as an
    # event. Returns false when the deadline passed first.
    def stream_events(io, waiter, deadline, secrets, &on_event)
      buffer = String.new(encoding: Encoding::BINARY)
      skipping = false
      exited_at = nil

      loop do
        return false if monotonic >= deadline

        # Claude Code exited but something it started still holds stdout.
        unless waiter.alive?
          exited_at ||= monotonic
          break if monotonic - exited_at > OUTPUT_DRAIN_GRACE
        end

        next unless io.wait_readable([ POLL_INTERVAL, time_left(deadline) || POLL_INTERVAL ].min)

        chunk = io.read_nonblock(64 * 1024, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable

        buffer << chunk
        while (newline = buffer.index("\n"))
          line = buffer.slice!(0, newline + 1)
          if skipping
            skipping = false
          else
            emit_event(line, secrets, &on_event)
          end
        end

        next unless buffer.bytesize > MAX_EVENT_LINE_BYTES

        unless skipping
          head = buffer.byteslice(0, CodeSession::MAX_EVENT_STRING).force_encoding(Encoding::UTF_8).scrub
          emit_event("#{head}… (line truncated)", secrets, &on_event)
        end
        buffer.clear
        skipping = true
      end

      emit_event(buffer, secrets, &on_event) unless skipping || buffer.empty?
      true
    end

    def emit_event(line, secrets)
      text = line.dup.force_encoding(Encoding::UTF_8).scrub.chomp
      return if text.strip.empty?

      event = begin
        parsed = JSON.parse(text)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
      yield SecretScrubber.scrub(event || { "type" => "raw", "text" => text }, secrets) if block_given?
    end

    def write_prompt(io, prompt)
      io.write(prompt.to_s)
    rescue IOError, SystemCallError
      # The CLI exited without reading it; its exit status says why.
    ensure
      io.close unless io.closed?
    end

    def copy_stderr(io, log, secrets, tail)
      File.open(log, "a") do |file|
        io.each_line(64 * 1024) do |line|
          line = SecretScrubber.scrub(line.scrub, secrets)
          file.write(line)
          file.flush
          tail << line.chomp.truncate(500)
          tail.shift while tail.size > LOG_TAIL_LINES
        end
      end
    rescue IOError
      # Closed under us once the session is over.
    end

    # The checkout's changes since it was fetched: this session's, and any
    # earlier session's. Untracked files are marked intent-to-add so new
    # files show up alongside edits. `add --all` also stages removals, which
    # a plain `git diff` (worktree against index) would then leave out, so
    # the worktree is compared with the commit checked out instead; that also
    # keeps changes the session committed itself.
    def capture_diff(workspace, secrets)
      app = workspace.join("app")
      env = self.class.sanitized_environment
      git = git_command(app)
      # A filter driver in the checkout's git config (which the session could
      # have written) runs its command on `git add` and `git diff`, as the
      # dashboard's user. Rather than run it, report no diff.
      drivers, = capture(env, [ *git, "config", "--local", "--includes", "--name-only", "--get-regexp", "^filter\\." ],
        chdir: app, limit: 64 * 1024, timeout: GIT_TIMEOUT)
      if drivers.to_s.strip.present?
        return "(diff not recorded: the checkout's git config defines filter drivers, which would run commands)"
      end
      capture(env, [ *git, "add", "--intent-to-add", "--all" ], chdir: app, limit: 64 * 1024, timeout: GIT_TIMEOUT)

      base = read_state(workspace)["checkout_commit"]
      base = "HEAD" unless base.is_a?(String) && COMMIT_ID.match?(base)
      diff = ->(commit) do
        capture(env, [ *git, "diff", "--no-color", "--no-ext-diff", "--no-textconv", commit, "--" ],
          chdir: app, limit: MAX_DIFF_BYTES, timeout: GIT_TIMEOUT)
      end
      output, status = diff.call(base)
      # The session pruned the commit away (a gc after moving HEAD, say).
      output, = diff.call("HEAD") if base != "HEAD" && output.empty? && status && !status.success?

      SecretScrubber.scrub(output.force_encoding(Encoding::UTF_8).scrub, secrets)
    rescue SystemCallError => e
      Rails.logger.warn("[ActionAgent] could not diff the sandbox checkout: #{e.message}")
      ""
    end

    # git in the checkout. A Claude Code session could have edited
    # .git/config: whatever hooks or filesystem monitor it set up there do
    # not run here.
    def git_command(app)
      [ "git", "-C", app.to_s, "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" ]
    end

    def sandbox_secrets(sandbox, credentials)
      token = begin
        sandbox.checkout_spec&.dig(:token)
      rescue StandardError
        nil
      end
      [ token, *credentials.values ].compact.map(&:to_s)
    end

    # Drops the session's pid, and a cancel it may have left unanswered.
    def forget_code_session(workspace, key)
      update_state(workspace, create: false) do |state|
        pid = state_hash(state, "code_sessions").delete(key)
        state_hash(state, "process_starts").delete(pid.to_s) if pid
        state_hash(state, "cancelled_code_sessions").delete(key)
      end
    rescue Errno::ENOENT
      # Terminated meanwhile: the workspace, and its state, are gone.
    end

    def exit_code(status)
      status.exitstatus || (status.termsig ? 128 + status.termsig : 1)
    end

    # --- Processes ----------------------------------------------------------

    # Every sandbox process leads its own process group, so stopping one
    # reaches whatever it started, and gets exactly the environment given.
    def spawn_group(env, *argv, chdir:, **redirects)
      Process.spawn(env, *argv, chdir: chdir.to_s, pgroup: true, unsetenv_others: true, close_others: true, **redirects)
    end

    # Runs +argv+ to completion, bounded in time and output. Returns the
    # output and the exit status (nil when it had to be stopped).
    def capture(env, argv, chdir:, limit:, timeout:, err: File::NULL)
      output = String.new(encoding: Encoding::BINARY)
      reader, writer = IO.pipe
      pid = spawn_group(env, *argv, chdir: chdir, in: File::NULL, out: writer, err: err)
      writer.close
      waiter = Process.detach(pid)
      deadline = deadline_after(timeout)

      while output.bytesize < limit && monotonic < deadline
        next unless reader.wait_readable([ POLL_INTERVAL, time_left(deadline) || POLL_INTERVAL ].min)

        chunk = reader.read_nonblock(64 * 1024, exception: false)
        break if chunk.nil?

        output << chunk.byteslice(0, limit - output.bytesize) unless chunk == :wait_readable
      end

      [ output, waiter.join(output.bytesize < limit ? time_left(deadline) : 0) && waiter.value ]
    ensure
      stop_groups([ pid ], grace: 1) if pid
      [ reader, writer ].each { |io| io&.close unless io&.closed? }
    end

    # TERM to each group, KILL to whatever is left after +grace+, then a
    # moment for the kernel to finish them off.
    def stop_groups(pids, grace: STOP_GRACE)
      live = pids.select { |pid| group_alive?(pid) }
      return if live.empty?

      live.each { |pid| signal_group(pid, "TERM") }
      deadline = deadline_after(grace)
      sleep 0.1 while live.any? { |pid| group_alive?(pid) } && monotonic < deadline

      live.each { |pid| signal_group(pid, "KILL") if group_alive?(pid) }
      deadline = deadline_after(2)
      sleep 0.05 while live.any? { |pid| group_alive?(pid) } && monotonic < deadline
    end

    def signal_group(pgid, signal)
      return false unless signalable?(pgid)

      Process.kill(signal, -pgid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # Never 0 or 1 (kill(-1) signals every process the user owns) and never
    # the dashboard's own group.
    def signalable?(pgid)
      pgid.is_a?(Integer) && pgid > 1 && pgid != Process.getpgrp
    end

    # Whether any live process remains in group +pgid+. Where /proc exists it
    # is read directly: kill(0) also succeeds for zombies, which an init that
    # does not reap (a container's) keeps around indefinitely.
    def group_alive?(pgid)
      return false unless signalable?(pgid)
      return proc_group_alive?(pgid) if procfs?

      Process.kill(0, -pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def proc_group_alive?(pgid)
      Dir.each_child("/proc").any? do |entry|
        next false unless entry.match?(/\A\d+\z/)

        state, _ppid, group = proc_stat(entry)
        group.to_i == pgid && !%w[Z X].include?(state)
      end
    end

    # The fields of /proc/<pid>/stat after the command name, which may itself
    # contain spaces and parentheses.
    def proc_stat(pid)
      stat = File.read("/proc/#{pid}/stat")
      stat[(stat.rindex(")") + 2)..].split
    rescue SystemCallError
      []
    end

    def procfs?
      File.exist?("/proc/self/stat")
    end

    # When process +pid+ started, in clock ticks since boot: what tells it
    # apart from a later process that reused its pid. Unlike its environment
    # the process cannot rewrite it, as a long enough process title (Ruby's
    # `$0=`, setproctitle) does. nil where /proc cannot say.
    def process_start(pid)
      # Field 22 of the stat line; proc_stat starts at field 3.
      return Integer(proc_stat(pid)[19], exception: false) if procfs?

      # No /proc (macOS): ps reports the start time to the second, enough to
      # tell a reused pid apart. nil when the process is gone.
      output, status = Open3.capture2("ps", "-o", "lstart=", "-p", pid.to_s)
      status.success? ? output.strip.presence : nil
    rescue SystemCallError
      nil
    end

    def record_process_start(state, pid)
      started = process_start(pid)
      state_hash(state, "process_starts")[pid.to_s] = started if started
    end

    # Whether +pid+, read from state.json, may be signalled as this
    # sandbox's process group. A pid is reused once its process is gone, so
    # where /proc shows the process it must be the one recorded: started
    # when state.json says, or, for a pid recorded without a start time,
    # carrying this sandbox's session id in its environment. Where it is gone
    # there is nothing to confuse: a group id is not reused while any process
    # of the group lives.
    def recorded_group?(pid, session_id, state)
      return false unless signalable?(pid)

      started = state["process_starts"][pid.to_s] if state["process_starts"].is_a?(Hash)
      if started
        current = process_start(pid)
        return current.nil? || current == started
      end
      # Nothing to identify it by (no start time recorded, and no /proc to
      # read its environment): never signal a pid that may have been reused.
      return false unless procfs?

      environ = File.binread("/proc/#{pid}/environ")
      # A zombie's environment reads empty, and its pid is still its own.
      environ.empty? || environ.split("\0").include?("#{SESSION_ID_ENV}=#{session_id}")
    rescue Errno::ENOENT, Errno::ESRCH
      true
    rescue Errno::EACCES, Errno::EPERM
      false
    end

    # Stops everything the workspace recorded, then removes it. The
    # terminating mark goes in under the same lock that reads the pids: a
    # Claude Code session that records itself later finds the mark and stops
    # on its own (see #record_code_session), and one that recorded itself
    # earlier is among the pids stopped here.
    def discard(session_id)
      workspace = workspace_for(session_id)
      return unless workspace.exist?

      state = begin
        update_state(workspace) { |current| current["terminating"] = true }
      rescue Errno::ENOENT, Errno::ENOTDIR
        {}
      end
      sessions = state["code_sessions"].is_a?(Hash) ? state["code_sessions"].values : []
      stop_groups([ state["pid"], *sessions ].uniq.select { |pid| recorded_group?(pid, session_id, state) })
      remove_workspace(workspace)
    end

    # Moved aside before it is deleted: a Claude Code session finishing in
    # this process may still be diffing or updating state.json there, and
    # has to find the workspace gone rather than recreate parts of it.
    def remove_workspace(workspace)
      return unless workspace.exist?

      doomed = workspace.dirname.join(".#{workspace.basename}.removed-#{SecureRandom.hex(4)}")
      File.rename(workspace, doomed)
      3.times do
        FileUtils.rm_rf(doomed)
        break unless doomed.exist?

        sleep 0.2
      end
    rescue Errno::ENOENT
      # Removed meanwhile.
    end

    def background(&block)
      Thread.new(&block).tap { |thread| thread.report_on_exception = false }
    end

    def describe(status)
      status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"
    end

    # --- Workspace ----------------------------------------------------------

    def workspace_for(session_id)
      ActionAgent.local_sandbox_root.join(session_id)
    end

    def log_path(workspace, name)
      workspace.join("logs", "#{name}.log")
    end

    def session_id!(value)
      value = value.to_s
      raise Error, "#{value.inspect} is not a sandbox session id" unless SESSION_ID.match?(value)

      value
    end

    # The session id in a handle this backend issued, or nil for anything
    # else.
    def session_id_from(handle)
      handle = handle.to_s
      return nil unless handle.start_with?(HANDLE_PREFIX)

      session_id = handle.delete_prefix(HANDLE_PREFIX)
      SESSION_ID.match?(session_id) ? session_id : nil
    end

    def read_state(workspace)
      File.open(workspace.join("state.json"), File::RDONLY) do |file|
        file.flock(File::LOCK_SH)
        parse_state(file.read)
      end
    rescue Errno::ENOENT
      {}
    end

    # Read-modify-write under an exclusive lock: a Claude Code session
    # records its pid while terminate may be reading the same file.
    def update_state(workspace, create: true)
      File.open(workspace.join("state.json"), File::RDWR | (create ? File::CREAT : 0), 0o600) do |file|
        file.flock(File::LOCK_EX)
        state = parse_state(file.read)
        yield state
        file.rewind
        file.truncate(0)
        file.write(JSON.generate(state))
        file.flush
        state
      end
    end

    def parse_state(json)
      state = JSON.parse(json.presence || "{}")
      state.is_a?(Hash) ? state : {}
    rescue JSON::ParserError
      {}
    end

    # state[key] as a Hash, in place of whatever a damaged file held there.
    def state_hash(state, key)
      state[key] = {} unless state[key].is_a?(Hash)
      state[key]
    end

    # --- Time ---------------------------------------------------------------

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # No (or a non-positive) timeout means none.
    def deadline_after(seconds)
      seconds = seconds.to_f
      seconds.positive? ? monotonic + seconds : Float::INFINITY
    end

    # Seconds until +deadline+, or nil for no limit (what Thread#join and
    # IO#wait_readable take for "forever").
    def time_left(deadline)
      deadline.infinite? ? nil : [ deadline - monotonic, 0 ].max
    end
  end
end
