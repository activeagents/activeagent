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
  #     db/           its SQLite databases, if it uses SQLite (see
  #                   LocalSandboxDatabases; state.json records the
  #                   database variables it was given)
  #     runtime.json  the manifest the checkout wrote (see SandboxManifest)
  #     state.json    { pid, port, started_at, code_sessions: { "<id>" => pid } },
  #                   plus the commit checked out, the boot step running
  #                   (step_pid), when each recorded process started, cancels
  #                   sent and cancels that found nothing to stop yet,
  #                   whether a terminate is under way, and the boot's steps
  #                   and how each went (boot; see #boot_status)
  #     state.lock    what changes to state.json are serialized on
  #     logs/         checkout, setup, manifest, server and claude-<id> logs,
  #                   and with a boot spec preflight and one per spec step
  #     claude/       CLAUDE_CONFIG_DIR for Claude Code sessions (with
  #                   ActionAgent.claude_code_auth = :api_key; with
  #                   :local_login they use the user's own configuration)
  #
  # The orchestrator builds a new backend for every call, and the dashboard
  # may restart while a sandbox runs, so whatever a later call needs lives in
  # state.json rather than in instance variables. Calls race each other
  # through that file (a cancel or a terminate while Claude Code starts), so
  # it is only ever changed under an exclusive lock, and replaced whole (see
  # #update_state) so a crash never leaves it half written.
  #
  # How a checkout boots is up to its .activeagents/sandbox.yml (see Config),
  # or to the boot spec the engine hands create_sandbox (see SandboxBootSpec).
  # Every process starts from a sanitized copy of the dashboard's environment
  # (see .sanitized_environment), so a checkout never sees the dashboard's
  # database or secrets. The GitHub token reaches only the fetch, and the
  # Claude Code API key only Claude Code. With
  # ActionAgent.claude_code_auth = :local_login no credential is passed at
  # all: Claude Code runs on the machine's own login.
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
    # Between SIGTERM and SIGKILL when stopping a sandbox, or a cancelled
    # Claude Code session.
    STOP_GRACE = 10
    LOG_TAIL_LINES = 20
    LOG_TAIL_BYTES = 64 * 1024
    # A boot step's output is scrubbed a line at a time on its way to the
    # log; a longer line is cut into pieces of this size.
    LOG_LINE_BYTES = 64 * 1024
    # #boot_log pages.
    LOG_PAGE_BYTES = 64 * 1024
    MAX_LOG_PAGE_BYTES = 1024 * 1024
    LOG_NAME = /\A[a-z][a-z0-9_]{0,39}\z/
    # Listing the checkout's Rake tasks for a step's if_task.
    TASK_LIST_TIMEOUT = 120
    TASK_LIST_BYTES = 1024 * 1024
    # How long one GET of a boot spec's start_url may take: a development
    # server compiles on its first request.
    START_URL_READ_TIMEOUT = 60

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
    PS_ENVIRONMENT = { "TZ" => "UTC", "LC_ALL" => "C", "LANG" => "C" }.freeze
    # How often a running Claude Code session looks for a cancel in
    # state.json.
    CANCEL_CHECK_INTERVAL = 0.5
    # How long terminate waits on the checkout's database cleanup.
    DATABASE_DROP_TIMEOUT = 60
    DATABASE_DROP_TARGETS_ENV = "ACTION_AGENT_SANDBOX_DATABASE_DROP_TARGETS"
    # Runs in the checkout's Rails bundle. Filter its resolved configurations
    # before either checking protection or dropping anything. A url: added
    # after boot overrides DATABASE_URL in Rails, so require the recorded URL
    # itself as well as its adapter/database to match. No matching config
    # means no drop; legacy state without this allow-list is never inferred.
    DATABASE_DROP_SCRIPT = <<~'RUBY'.freeze
      require "json"
      targets = JSON.parse(ENV.fetch("ACTION_AGENT_SANDBOX_DATABASE_DROP_TARGETS"))
      selected = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).select do |config|
        url = targets[config.name]
        next false unless url.is_a?(String)

        expected = ActiveRecord::DatabaseConfigurations::UrlConfig.new(Rails.env, config.name, url, {})
        config.is_a?(ActiveRecord::DatabaseConfigurations::UrlConfig) && config.url == url &&
          config.adapter == expected.adapter && config.database == expected.database
      end
      ActiveRecord::Base.configurations = selected
      ActiveRecord::Tasks::DatabaseTasks.check_protected_environments!(Rails.env)
      selected.each { |config| ActiveRecord::Tasks::DatabaseTasks.drop(config) }
    RUBY
    MODEL_NAME = %r{\A[A-Za-z0-9][A-Za-z0-9._:/@\[\]-]{0,127}\z}
    # `claude auth status`: how long its answer is trusted, how long it may
    # take, and what its authMethod and apiProvider may look like to be
    # shown (a short label, never free text).
    LOGIN_STATUS_TTL = 60
    # A logged-out answer is re-asked soon: someone who just ran
    # `claude /login` clicks "Check again" and expects it to turn green.
    LOGGED_OUT_STATUS_TTL = 3
    LOGIN_STATUS_TIMEOUT = 10
    LOGIN_LABEL = /\A[A-Za-z0-9][A-Za-z0-9._ -]{0,63}\z/
    LOGGED_OUT = { logged_in: false, auth_method: nil, api_provider: nil }.freeze

    # Never inherited from the dashboard: its database, its keys, and the
    # Ruby/Bundler setup of its own bundle (a checkout has its own Gemfile).
    DROPPED_VARIABLES = %w[
      DATABASE_URL REDIS_URL SECRET_KEY_BASE RAILS_MASTER_KEY RAILS_ENV RACK_ENV PORT
      BUNDLE_GEMFILE RUBYOPT RUBYLIB
      SSH_AUTH_SOCK
    ].freeze
    DROPPED_VARIABLE_PATTERN = /
      _DATABASE_URL\z | \AACTIVE_RECORD_ENCRYPTION_ | \ABUNDLER?_ |
      # Where git finds a repository, and its configuration. Set when the
      # dashboard runs under a git hook, and they would point the checkout's
      # git at the dashboard's own repository or config.
      \AGIT_(?:DIR|WORK_TREE|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|COMMON_DIR|
        NAMESPACE|PREFIX|QUARANTINE_PATH|CONFIG|CONFIG_PARAMETERS|CONFIG_COUNT|CONFIG_KEY_\d+|CONFIG_VALUE_\d+|
        CONFIG_GLOBAL|CONFIG_SYSTEM|CONFIG_NOSYSTEM)\z |
      # The dashboard's own model-provider and Claude Code settings. A
      # developer often runs the dashboard from inside Claude Code, which
      # exports CLAUDECODE, CLAUDE_CODE_* (its own session id among them) and
      # ANTHROPIC_BASE_URL; a session inheriting those joins the developer's
      # session, and a base URL redirects the owner's credential. A session
      # gets exactly the Claude Code variables the backend sets.
      \A(?:ANTHROPIC|CLAUDE|CODEX|OPENAI|OPEN_AI|OPENROUTER|OPEN_ROUTER|OLLAMA)(?:_|\z) | \ACLAUDECODE\z
    /x
    SECRET_VARIABLE = /
      SECRET | TOKEN | PASSWORD | PASSWD | PASSPHRASE | API_KEY | APIKEY | PRIVATE_KEY | CREDENTIAL | ACCESS_KEY |
      # DB_PASS, MYSQL_PWD, LOCKBOX_MASTER_KEY, SENTRY_DSN, SLACK_WEBHOOK_URL, GITHUB_PAT
      (?:\A|_)PASS\z | (?:\A|_)PWD\z | _KEY\z | DSN\z | WEBHOOK | (?:\A|_)PAT\z
    /xi
    # A URL carrying credentials, whatever its name: a password
    # (redis://:secret@host) or a token as the username alone
    # (https://ghp_x@github.com). Any userinfo counts, anywhere in the value.
    CREDENTIALED_URL = %r{[a-z][a-z0-9+.-]*://[^/\s@]+@}i

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

    # What a boot runs once the checkout is there: the steps of the
    # checkout's sandbox.yml (mode "config") or of a boot spec (mode "spec"),
    # then manifest, then start. +label+ is what a failure message calls the
    # step, +log+ the file under logs/ its output goes to, and +skip+ why it
    # will not run, when that is known before the boot starts.
    BootStep = Struct.new(:name, :command, :timeout, :log, :label, :if_task, :skip, keyword_init: true)
    BootPlan = Struct.new(:mode, :spec, :steps, :manifest, :start, :env, :start_url, :keep_on_failure, :offset,
      keyword_init: true) do
      def entries
        [ *steps, manifest, start ]
      end
    end
    # What a step's block returns when the step had nothing to do.
    Skip = Struct.new(:reason)

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
    @login_status = {}
    @login_status_lock = Mutex.new

    class << self
      # Whether this machine's Claude Code is logged in, for
      # ActionAgent.claude_code_auth = :local_login: what
      # `<claude_code_command> auth status --json` says, run with the
      # sanitized environment (so it reads the user's own ~/.claude, as a
      # session will) and bounded in time.
      #
      # Only whether it is logged in and how (authMethod, apiProvider) is
      # kept. The rest of that output (an account's email, its organization)
      # is never logged, stored or returned, and the credential itself is
      # never in it. A CLI that is missing, fails or answers something else
      # reads as logged out.
      #
      # Asked at most once a LOGIN_STATUS_TTL per command (a logged-out
      # answer, LOGGED_OUT_STATUS_TTL): the listing that shows it is polled.
      #
      # @return [Hash] { logged_in: Boolean, auth_method: String?, api_provider: String? }
      def claude_login_status
        command = ActionAgent.claude_code_command.to_s
        @login_status_lock.synchronize do
          cached = @login_status[command]
          return cached[:status] if cached && Process.clock_gettime(Process::CLOCK_MONOTONIC) < cached[:until]
        end

        status = new.send(:read_claude_login_status, command)
        @login_status_lock.synchronize do
          @login_status[command] = {
            status: status,
            until: Process.clock_gettime(Process::CLOCK_MONOTONIC) +
              (status[:logged_in] ? LOGIN_STATUS_TTL : LOGGED_OUT_STATUS_TTL)
          }
        end
        status
      end

      # Forgets the cached login status, so the next call asks the CLI again.
      def reset_claude_login_status!
        @login_status_lock.synchronize { @login_status.clear }
      end

      # The fields of `claude auth status --json` the dashboard keeps.
      def parse_login_status(output)
        data = JSON.parse(output.to_s.strip)
        return LOGGED_OUT unless data.is_a?(Hash) && data["loggedIn"] == true

        {
          logged_in: true,
          auth_method: login_label(data["authMethod"]),
          api_provider: login_label(data["apiProvider"])
        }
      rescue JSON::ParserError
        LOGGED_OUT
      end

      private

      def login_label(value)
        value if value.is_a?(String) && LOGIN_LABEL.match?(value)
      end
    end

    # Clones the session's checkout, boots it as sandbox.yml says (or as
    # +boot_config+ says, see SandboxBootSpec), and waits until its MCP
    # facade answers.
    #
    # @return [Hash] the handle (container_name), url, mcp_url and mcp_token
    def create_sandbox(session, instance_tier: nil, boot_config: nil)
      ensure_enabled!
      unless session.app_runtime?
        raise Error, "The local sandbox backend only boots app_runtime checkouts, not #{session.sandbox_type} sandboxes"
      end

      boot_spec = boot_spec!(boot_config)
      spec = session.checkout_spec
      raise Error, "Sandbox #{session.session_id} has no checkout to boot (is GitHub still connected?)" if spec.blank?

      session_id = session_id!(session.session_id)
      # A retried provision (say the dashboard restarted mid-boot) starts
      # clean rather than on a half-built checkout next to a stray server.
      unless discard(session_id)
        raise Error, "Sandbox #{session_id} still has processes from an earlier boot that could not be stopped; " \
          "see the dashboard log"
      end
      boot(session_id, spec, [ spec[:token], *session.runtime_environment.values, *boot_spec&.secret_values ], boot_spec)
    end

    # Continues a boot that failed and kept its workspace (a boot spec with
    # keep_on_failure): re-runs it from the step named +from+, or from the
    # step that failed when +from+ is nil, on the same checkout and
    # databases. Nothing is cloned again and no earlier step runs again.
    # +boot_config+ replaces the spec the boot started with, for new env or
    # secrets; without one the recorded spec is used, which holds no secret
    # values, so a boot whose spec had secrets needs it passed again.
    #
    # @return [Hash] what #create_sandbox returns
    def resume_boot(session, from:, boot_config: nil)
      ensure_enabled!
      session_id = session_id!(session.session_id)
      workspace = workspace_for(session_id)
      boot_state = read_state(workspace)["boot"]
      unless boot_state.is_a?(Hash) && boot_state["kept"] == true
        raise Error, "Sandbox #{session_id} has no failed boot kept to resume: start it again"
      end

      spec = boot_spec!(boot_config) || boot_spec!(boot_state["spec"])
      raise Error, "Sandbox #{session_id} was not booted from a boot spec, so it cannot be resumed" if spec.nil?
      if spec.missing_secrets.any?
        raise Error, "Resuming sandbox #{session_id} needs its boot spec again: the values of " \
          "#{spec.missing_secrets.join(", ")} are never kept"
      end

      plan = spec_plan(spec, Array(boot_state["locked_gems"]).to_set)
      start_at = resume_position(plan, from.presence || boot_state["failed_step"])
      unless claim_kept_boot(workspace)
        raise Error, "Sandbox #{session_id} has no failed boot kept to resume: it is being resumed, or was stopped"
      end

      checkout = begin
        session.checkout_spec
      rescue StandardError
        nil
      end
      secrets = [ checkout&.dig(:token), *session.runtime_environment.values, *spec.secret_values ]
      resume(workspace, plan, start_at, secrets)
    end

    # How the sandbox's boot went, step by step (see
    # SandboxOrchestrator#boot_status); nil when it has no workspace.
    def boot_status(session)
      session_id = session_id!(session.session_id)
      boot_state = read_state(workspace_for(session_id))["boot"]
      return nil unless boot_state.is_a?(Hash) && boot_state["steps"].is_a?(Array)

      secrets = session_secrets(session)
      {
        mode: boot_state["mode"],
        kind: boot_state["kind"],
        failed_step: boot_state["failed_step"],
        kept: boot_state["kept"] == true,
        resumable_steps: resumable_step_names(boot_state),
        steps: boot_state["steps"].filter_map do |step|
          next unless step.is_a?(Hash)

          {
            name: step["name"], status: step["status"], started_at: step["started_at"], finished_at: step["finished_at"],
            duration_ms: step["duration_ms"] || running_for(step["started_at"]),
            detail: step["detail"] && SecretScrubber.scrub(step["detail"].to_s, secrets)
          }
        end
      }
    end

    # One page of a boot step's log (see SandboxOrchestrator#boot_log).
    def boot_log(session, step:, offset: 0, limit: LOG_PAGE_BYTES, secrets: [])
      session_id = session_id!(session.session_id)
      workspace = workspace_for(session_id)
      boot_state = read_state(workspace)["boot"]
      steps = boot_state.is_a?(Hash) && boot_state["steps"].is_a?(Array) ? boot_state["steps"] : []
      entry = steps.find { |candidate| candidate.is_a?(Hash) && candidate["name"] == step.to_s }
      return nil unless entry && LOG_NAME.match?(entry["log"].to_s)

      path = log_path(workspace, entry["log"])
      return nil unless path.file?

      size = path.size
      offset = Integer(offset, exception: false).to_i.clamp(0, size)
      limit = Integer(limit, exception: false).to_i.clamp(1, MAX_LOG_PAGE_BYTES)
      data = File.open(path, "rb") do |file|
        file.seek(offset)
        file.read(limit).to_s
      end
      # Ends on a line break when the page stops short of the end, so a
      # value the scrubber masks is never split across two pages.
      if offset + data.bytesize < size && (newline = data.rindex("\n"))
        data = data.byteslice(0, newline + 1)
      end
      next_offset = offset + data.bytesize

      {
        step: entry["name"], offset: offset, next_offset: next_offset, size: size, eof: next_offset >= size,
        text: SecretScrubber.scrub(data.force_encoding(Encoding::UTF_8).scrub, session_secrets(session) + Array(secrets))
      }
    end

    # A sandbox's handle follows from its session id, so one whose boot was
    # never recorded can still be found and stopped.
    def handle_for(session)
      "local-#{session.session_id}"
    end

    # Stops the sandbox's server, its boot step and any Claude Code sessions
    # it recorded, then removes its workspace. Returns true, also when there
    # was nothing to stop.
    #
    # False when something the sandbox recorded is still alive and could
    # not be stopped (or told apart from an unrelated process): its
    # workspace, and state.json with it, is kept, so the handle is kept for
    # the reaper to try again.
    def terminate(handle)
      session_id = session_id_from(handle)
      session_id ? discard(session_id) : true
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

    def code_runners
      %w[claude_code codex]
    end

    # Runs a coding agent headless in the sandbox's checkout, yielding each
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

      runner = code_session.try(:runner) || "claude_code"
      raise Error, "Unsupported code runner: #{runner}" unless code_runners.include?(runner)

      credentials = session_credentials(sandbox, runner: runner)
      secrets = sandbox_secrets(sandbox, credentials)
      argv = runner == "codex" ? codex_argv(code_session) : claude_argv(code_session)
      database_env = read_state(workspace)["database_env"]
      env = self.class.sanitized_environment
        .merge(database_env.is_a?(Hash) ? database_env.transform_values(&:to_s) : {})
        .merge(credentials.to_h { |name, value| [ name.to_s, value.to_s ] })
        .merge(
          SESSION_ID_ENV => session_id,
          "DISABLE_AUTOUPDATER" => "1",
          "DISABLE_TELEMETRY" => "1",
          "DISABLE_ERROR_REPORTING" => "1",
          "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"
        )
      # With an API key a session gets a Claude Code configuration of its
      # own, in the workspace. With the machine's own login it must use the
      # user's: that is where `claude /login` left the credentials (HOME,
      # which the sanitized environment keeps, or the keychain).
      if runner == "codex"
        env["CODEX_HOME"] = workspace.join("codex").to_s
        FileUtils.mkdir_p(workspace.join("codex"), mode: 0o700)
      elsif !ClaudeCodeAuth.local_login?
        env["CLAUDE_CONFIG_DIR"] = workspace.join("claude").to_s
        FileUtils.mkdir_p(workspace.join("claude"), mode: 0o700)
      end

      run_claude(workspace, code_session, argv, env, secrets, runner: runner, &on_event)
    end

    # Stops a running Claude Code session: SIGTERM to its process group. The
    # run_code_session that started it then finishes with what it has. The
    # cancel is noted in state.json too, and run_code_session, which watches
    # for it, sends SIGKILL once STOP_GRACE has passed: a CLI that ignores
    # SIGTERM would otherwise run on until claude_code_timeout.
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
          if recorded_group?(pid, session_id, state)
            signal_group(pid, "TERM")
            # Wall-clock time: the session may run in another process.
            state_hash(state, "cancelling_code_sessions")[key] ||= Time.now.to_f
          end
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

    def boot_spec!(value)
      SandboxBootSpec.wrap(value)
    rescue SandboxBootSpec::Invalid => e
      raise Error, "Sandbox boot spec is invalid: #{e.message}"
    end

    # The secrets a sandbox's stored output is scrubbed of when it is read
    # back: its checkout token, the credentials its sessions get, and the
    # secrets of the project it was booted for.
    def session_secrets(session)
      token = begin
        session.checkout_spec&.dig(:token)
      rescue StandardError
        nil
      end
      [ token, *session.runtime_environment.values, *Array(session.try(:project_scrub_values)) ].compact.map(&:to_s)
    end

    # Milliseconds since +started_at+ (an ISO 8601 time), for a step still
    # running; nil without one.
    def running_for(started_at)
      return nil unless started_at.is_a?(String)

      ((Time.current - Time.iso8601(started_at)) * 1000).round
    rescue ArgumentError
      nil
    end

    def ensure_enabled!
      return if ActionAgent.local_sandboxes_enabled?

      raise Error, "Local sandboxes are disabled. They run checkouts and Claude Code as processes on this machine; " \
        "set ActionAgent.local_sandboxes_enabled = true to allow them"
    end

    # --- Boot -------------------------------------------------------------

    def boot(session_id, checkout, secrets, boot_spec = nil)
      workspace = workspace_for(session_id)
      started = monotonic
      # A spec only for checkouts without the engine may not apply, which is
      # known once the checkout is there: until then, and when it does not,
      # the boot has the configured limit.
      reset_boot(boot_spec && !boot_spec.without_engine_only? ? spec_boot_timeout(boot_spec) : ActionAgent.local_sandbox_boot_timeout)
      deadline = deadline_after(@boot_timeout)
      booted = false
      keep = false

      prepare_workspace(workspace)
      update_state(workspace) do |state|
        state["boot"] = { "steps" => [ { "name" => "checkout", "log" => "checkout", "status" => "pending" } ], "kept" => false }
      end
      boot_step(workspace, 0) { checkout!(workspace, checkout, secrets, deadline) }

      app = workspace.join("app")
      plan = plan_boot(workspace, app, checkout, boot_spec)
      if plan.spec && spec_boot_timeout(plan.spec) != @boot_timeout
        @boot_timeout = spec_boot_timeout(plan.spec)
        deadline = started + @boot_timeout
      end
      databases = assign_databases(workspace, app, plan.env, checkout)
      # Only from here on does a kept workspace hold all a resume needs.
      keep = plan.keep_on_failure
      result = run_plan!(workspace, plan, boot_environment(workspace, databases, plan), 0, deadline, secrets)
      booted = true
      result
    rescue Error
      raise
    rescue StandardError => e
      raise Error, SecretScrubber.scrub("Sandbox boot failed: #{e.class.name}: #{e.message}", secrets)
    ensure
      finish_failed_boot(workspace, keep) unless booted
    end

    # Takes a kept boot for one resume, under the state.json lock, so two
    # resumes never run in one workspace. False when there is none to take,
    # including while a terminate is removing the workspace.
    def claim_kept_boot(workspace)
      claimed = false
      update_state(workspace, create: false) do |state|
        boot_state = state["boot"]
        next if state["terminating"]
        next unless boot_state.is_a?(Hash) && boot_state["kept"] == true

        boot_state["kept"] = false
        claimed = true
      end
      claimed
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    end

    # Runs a kept boot's +plan+ again from its entry +start_at+.
    def resume(workspace, plan, start_at, secrets)
      reset_boot(spec_boot_timeout(plan.spec))
      deadline = deadline_after(@boot_timeout)
      booted = false
      keep = plan.keep_on_failure

      database_env = read_state(workspace)["database_env"]
      databases = database_env.is_a?(Hash) ? database_env.transform_values(&:to_s) : {}
      record_resumed_plan(workspace, plan, start_at)
      result = run_plan!(workspace, plan, boot_environment(workspace, databases, plan), start_at, deadline, secrets)
      booted = true
      result
    rescue Error
      raise
    rescue StandardError => e
      raise Error, SecretScrubber.scrub("Sandbox boot failed: #{e.class.name}: #{e.message}", secrets)
    ensure
      finish_failed_boot(workspace, keep) unless booted
    end

    # The limit on a boot from +spec+. A bootstrap does more than the app's
    # own boot from its sandbox.yml, so it never gets less time than
    # `local_sandbox_boot_timeout` gives that boot.
    def spec_boot_timeout(spec)
      spec.kind == "bootstrap" ? [ spec.timeout, ActionAgent.local_sandbox_boot_timeout ].max : spec.timeout
    end

    # What a boot remembers while it runs, which a backend instance holds for
    # one call: the limit on the whole boot, the server it started and the
    # checkout's Rake tasks once listed.
    def reset_boot(timeout)
      @boot_timeout = timeout
      @server_pid = nil
      @app_tasks = nil
    end

    # A failed boot leaves nothing running. Unless it is kept, it leaves
    # nothing on disk either: no handle was reported, so nothing would ever
    # reap it. The error carries the failing step's log tail.
    def finish_failed_boot(workspace, keep)
      stop_groups([ @server_pid ].compact)
      if keep && workspace.directory?
        update_state(workspace, create: false) { |state| state_hash(state, "boot")["kept"] = true }
      else
        # A setup that got as far as db:prepare created the databases.
        drop_databases(workspace)
        remove_workspace(workspace)
      end
    rescue SystemCallError => e
      Rails.logger.warn("[ActionAgent] sandbox #{workspace.basename}: could not finish a failed boot: #{e.message}")
    end

    def boot_environment(workspace, databases, plan)
      self.class.sanitized_environment.merge(databases).merge(plan.env).merge(
        # Merged after the file's env, so a checkout cannot move them.
        SandboxManifest::PATH_ENV => workspace.join("runtime.json").to_s,
        SESSION_ID_ENV => workspace.basename.to_s
      )
    end

    # Runs +plan+'s entries from +start_at+ on, records each in state.json as
    # it goes, and returns what #create_sandbox does.
    def run_plan!(workspace, plan, env, start_at, deadline, secrets)
      app = workspace.join("app")
      plan.steps.each_with_index do |step, index|
        next if index < start_at

        boot_step(workspace, plan.offset + index) do
          reason = step.skip || missing_task(workspace, step, env, deadline, secrets)
          if reason
            File.open(log_path(workspace, step.log), "a") { |file| file.puts("# skipped: #{reason}") }
            next Skip.new(reason)
          end

          run_step!(workspace, step.label, step.command, env: env, chdir: app, deadline: deadline, secrets: secrets,
            timeout: step.timeout, log: step.log)
        end
      end

      # Picked after setup, which can take minutes, so that the port is
      # likely still free when the server binds it. Nothing reserves it
      # meanwhile: #wait_until_ready! only accepts an answer from a listener
      # of the server's own process group.
      port = free_port
      env = env.merge("PORT" => port.to_s)
      manifest_index = plan.steps.size
      manifest = if start_at > manifest_index
        read_manifest!(workspace, plan.manifest, secrets)
      else
        boot_step(workspace, plan.offset + manifest_index) { run_manifest!(workspace, plan.manifest, env, deadline, secrets) }
      end

      boot_step(workspace, plan.offset + manifest_index + 1) do
        server_pid, waiter = start_server(workspace, plan.start.command, env, port)
        start_deadline = step_deadline(plan.start, deadline)
        wait_until_ready!(workspace, port, manifest, server_pid, waiter, start_deadline, secrets, step: plan.start, boot_deadline: deadline)
        probe_start_url!(workspace, port, plan.start_url, waiter, start_deadline, secrets, step: plan.start, boot_deadline: deadline) if plan.start_url
      end

      {
        container_name: "#{HANDLE_PREFIX}#{workspace.basename}",
        url: "http://127.0.0.1:#{port}",
        container_ip: "127.0.0.1",
        mcp_url: "http://127.0.0.1:#{port}#{manifest["mcp_path"]}",
        mcp_token: manifest["mcp_token"],
        created_at: Time.current
      }
    end

    # Records the boot's entry at +position+ in state.json as running, then
    # as succeeded, skipped (the block returned a Skip) or failed, and names
    # a failed one as the boot's failed_step. Returns the block's value.
    def boot_step(workspace, position)
      update_boot_step(workspace, position, "status" => "running", "started_at" => Time.current.iso8601(3),
        "finished_at" => nil, "duration_ms" => nil, "detail" => nil)
      started = monotonic
      outcome = nil
      finished = false
      error = nil
      begin
        outcome = yield
        finished = true
      rescue StandardError => e
        error = e
        raise
      ensure
        result =
          if !finished then { "status" => "failed", "detail" => error.is_a?(Error) ? error.message.lines.first.to_s.strip : nil }
          elsif outcome.is_a?(Skip) then { "status" => "skipped", "detail" => outcome.reason }
          else { "status" => "succeeded" }
          end
        update_boot_step(workspace, position,
          result.merge("finished_at" => Time.current.iso8601(3), "duration_ms" => ((monotonic - started) * 1000).round))
      end
      outcome
    end

    def update_boot_step(workspace, position, attributes)
      update_state(workspace, create: false) do |state|
        boot_state = state_hash(state, "boot")
        step = Array(boot_state["steps"])[position]
        next unless step.is_a?(Hash)

        step.merge!(attributes)
        boot_state["failed_step"] = step["name"] if attributes["status"] == "failed"
      end
    rescue SystemCallError
      # The workspace is gone: nothing left to record it in.
    end

    # Decides how the checkout boots, records the plan in state.json, and
    # returns it. A boot spec that applies runs its preflight here, before
    # any of the checkout's own commands.
    def plan_boot(workspace, app, checkout, boot_spec)
      facts = nil
      if boot_spec && spec_applies?(boot_spec, app)
        if boot_spec.preflight?
          position = append_boot_steps(workspace, [ { "name" => "preflight", "log" => "preflight", "status" => "pending" } ])
          facts = boot_step(workspace, position) { preflight!(workspace, app, checkout) }
        else
          facts = lock_facts(app.join("Gemfile.lock")) if app.join("Gemfile.lock").file?
        end
        plan = spec_plan(boot_spec, (facts&.dig("gems") || {}).keys.to_set)
      else
        plan = config_plan(Config.load(app), secrets: boot_spec&.secrets || {})
      end

      update_state(workspace) do |state|
        boot_state = state_hash(state, "boot")
        boot_state["mode"] = plan.mode
        if plan.spec
          boot_state["kind"] = plan.spec.kind
          boot_state["spec"] = plan.spec.redacted
          boot_state["locked_gems"] = (facts&.dig("gems") || {}).keys.sort
          boot_state["lock"] = facts&.except("gems")
        end
        steps = boot_state["steps"] = Array(boot_state["steps"])
        plan.offset = boot_state["plan_offset"] = steps.size
        steps.concat(plan.entries.map { |step| { "name" => step.name, "log" => step.log, "status" => "pending" } })
      end
      plan
    end

    # Appends +entries+ to the boot's steps; returns the first one's position.
    def append_boot_steps(workspace, entries)
      position = nil
      update_state(workspace) do |state|
        steps = state_hash(state, "boot")["steps"] = Array(state_hash(state, "boot")["steps"])
        position = steps.size
        steps.concat(entries)
      end
      position
    end

    # Rewrites the boot's steps for a resume from +start_at+: the entries
    # before it keep how they went, the rest are pending again.
    def record_resumed_plan(workspace, plan, start_at)
      update_state(workspace, create: false) do |state|
        boot_state = state_hash(state, "boot")
        steps = Array(boot_state["steps"])
        offset = Integer(boot_state["plan_offset"], exception: false) || steps.size
        earlier = steps.drop(offset).select { |step| step.is_a?(Hash) }.index_by { |step| step["name"] }
        resumed_from = plan.entries[start_at].name
        entries = plan.entries.each_with_index.map do |step, index|
          if index < start_at
            earlier[step.name] || { "name" => step.name, "log" => step.log, "status" => "skipped", "detail" => "not run: resumed from #{resumed_from}" }
          else
            { "name" => step.name, "log" => step.log, "status" => "pending" }
          end
        end
        plan.offset = offset
        boot_state.merge!("steps" => steps.first(offset) + entries, "failed_step" => nil, "kept" => false,
          "spec" => plan.spec.redacted, "plan_offset" => offset)
      end
    end

    def resume_position(plan, name)
      index = plan.entries.index { |step| step.name == name.to_s }
      return index if index

      raise Error, "#{name.inspect} is not a step this boot can resume from (#{plan.entries.map(&:name).join(", ")})"
    end

    # The steps #resume_position accepts: a spec boot's own, which follow
    # the checkout and preflight steps. None for a boot from the checkout's
    # sandbox.yml, which cannot be resumed.
    def resumable_step_names(boot_state)
      offset = Integer(boot_state["plan_offset"], exception: false)
      return [] unless boot_state["mode"] == "spec" && offset

      boot_state["steps"].drop(offset).filter_map { |step| step["name"] if step.is_a?(Hash) }
    end

    # +secrets+ are those of a boot spec that does not apply to the checkout:
    # it boots as its sandbox.yml says, with them added to that file's env.
    def config_plan(config, secrets: {})
      BootPlan.new(
        mode: "config", spec: nil,
        steps: config.setup.map { |command| BootStep.new(name: "setup", command: command, log: "setup", label: "setup") },
        manifest: BootStep.new(name: "manifest", command: config.manifest, log: "manifest", label: "manifest"),
        start: BootStep.new(name: "start", command: config.start, log: "server", label: "server"),
        env: config.env.merge(secrets), start_url: nil, keep_on_failure: false
      )
    end

    # +locked+ holds the names of the gems the checkout's Gemfile.lock locked
    # as it was checked out, before any step changed it.
    def spec_plan(spec, locked)
      steps = spec.steps.map do |entry|
        gem = entry["unless_locked"]
        BootStep.new(
          name: entry["name"], command: entry["command"], timeout: entry["timeout"], log: entry["name"], label: entry["name"],
          if_task: entry["if_task"], skip: (gem && locked.include?(gem) ? "the checkout already locks #{gem}" : nil)
        )
      end
      BootPlan.new(
        mode: "spec", spec: spec, steps: steps,
        manifest: BootStep.new(name: "manifest", command: spec.manifest["command"], timeout: spec.manifest["timeout"],
          log: "manifest", label: "manifest"),
        start: BootStep.new(name: "start", command: spec.start["command"], timeout: spec.start["timeout"], log: "server",
          label: "start"),
        env: spec.step_environment, start_url: spec.start_url, keep_on_failure: spec.keep_on_failure?
      )
    end

    # Whether +spec+ boots the checkout in +app+. One for checkouts without
    # the engine leaves alone a checkout that bundles it, one that says how
    # it serves its manifest itself, and anything without a Gemfile.lock.
    def spec_applies?(spec, app)
      return true unless spec.without_engine_only?

      lock = app.join("Gemfile.lock")
      return false unless lock.file?
      return false if lock.read.match?(/^ {4}actionagent \(/)

      file = app.join(Config::PATH)
      data = file.file? ? YAML.safe_load(file.read, aliases: false) : nil
      !(data.is_a?(Hash) && data.key?("manifest"))
    rescue Psych::Exception
      # Malformed: booting as configured reports what is wrong with it.
      false
    end

    # Refuses, before any of the checkout's commands runs, a checkout the
    # engine cannot be installed into. Returns what the checkout's
    # Gemfile.lock locks (see #lock_facts).
    def preflight!(workspace, app, checkout)
      repository = checkout[:repository].presence || "The checkout"
      log = log_path(workspace, "preflight")
      lock = app.join("Gemfile.lock")
      refuse = ->(problem) { fail_step!("preflight", problem, log, []) }

      refuse.call("#{repository} has no Gemfile.lock at its root: a bootstrap boot needs a bundled Rails app") unless lock.file?
      facts = lock_facts(lock)
      ruby, ruby_source = facts["ruby"] ? [ facts["ruby"], "Gemfile.lock" ] : [ ruby_version_file(app), ".ruby-version" ]
      railties = facts.dig("gems", "railties")
      File.open(log, "a") do |file|
        file.puts("Ruby #{ruby || "unpinned"}, railties #{railties || "not locked"}, " \
          "activeagent #{facts.dig("gems", "activeagent") || "not locked"}, actionagent #{facts.dig("gems", "actionagent") || "not locked"}")
      end

      if ruby && version_below?(ruby, SandboxBootSpec::MINIMUM_RUBY)
        refuse.call("#{repository} needs Ruby #{ruby} (#{ruby_source}); the engine needs Ruby #{SandboxBootSpec::MINIMUM_RUBY} or later")
      end
      refuse.call("#{repository}'s Gemfile.lock locks no railties: a bootstrap boot needs a Rails app") if railties.nil?
      if version_below?(railties, SandboxBootSpec::MINIMUM_RAILTIES)
        refuse.call("#{repository} locks railties #{railties}; the engine needs Rails #{SandboxBootSpec::MINIMUM_RAILTIES} or later")
      end
      unless app.join("config", "application.rb").file?
        refuse.call("#{repository} has no config/application.rb at its root: a bootstrap boot needs the Rails app at the repository root")
      end

      facts.merge("ruby" => ruby, "railties" => railties,
        "activeagent" => facts.dig("gems", "activeagent"), "actionagent" => facts.dig("gems", "actionagent"))
    end

    # What a Gemfile.lock locks: { "ruby" => "3.3.6" or nil, "gems" => { name => version } }.
    # Read in this process with Bundler's parser, which only parses.
    def lock_facts(path)
      parser = ::Bundler::LockfileParser.new(path.read)
      gems = parser.specs.each_with_object({}) { |spec, all| all[spec.name] ||= spec.version.to_s }
      { "ruby" => parser.ruby_version.to_s[/\d+\.\d+(?:\.\d+)?/], "gems" => gems }
    rescue StandardError => e
      raise Error, "Sandbox preflight failed: the checkout's Gemfile.lock could not be read (#{e.message.lines.first.to_s.strip.truncate(200)})"
    end

    def ruby_version_file(app)
      file = app.join(".ruby-version")
      file.file? ? file.read.lines.first.to_s.strip.delete_prefix("ruby-")[/\A\d+\.\d+(?:\.\d+)?/] : nil
    end

    def version_below?(version, minimum)
      Gem::Version.correct?(version) && Gem::Version.new(version) < minimum
    end

    # Why +step+ is skipped because the checkout defines no Rake task of its
    # if_task's name; nil when it has none, or the task exists.
    def missing_task(workspace, step, env, deadline, secrets)
      return nil unless step.if_task

      app_tasks(workspace, step, env, deadline, secrets).include?(step.if_task) ? nil : "the app defines no #{step.if_task} task"
    end

    # The checkout's Rake tasks, as `bin/rails -T -A` lists them, once per
    # boot: the first step that needs them runs it, after the steps before
    # it installed the bundle.
    def app_tasks(workspace, step, env, deadline, secrets)
      return @app_tasks if @app_tasks

      log = log_path(workspace, step.log)
      File.open(log, "a") { |file| file.puts("$ bin/rails -T -A") }
      timeout = [ time_left(step_deadline(step, deadline)) || TASK_LIST_TIMEOUT, TASK_LIST_TIMEOUT ].min
      output, status = capture(env, [ "bin/rails", "-T", "-A" ], chdir: workspace.join("app"), limit: TASK_LIST_BYTES,
        timeout: [ timeout, 1 ].max, err: [ :child, :out ])
      unless status&.success?
        File.open(log, "a") { |file| file.write(SecretScrubber.scrub(output.force_encoding(Encoding::UTF_8).scrub.last(LOG_TAIL_BYTES), secrets)) }
        fail_step!(step.label, "could not list the app's Rake tasks: `bin/rails -T -A` #{status ? "exited with #{describe(status)}" : "did not finish"}",
          log, secrets)
      end

      @app_tasks = output.force_encoding(Encoding::UTF_8).scrub.lines.filter_map { |line| line[/\A\S+\s+([^\s\[#]+)/, 1] }.to_set
    rescue SystemCallError => e
      fail_step!(step.label, "could not list the app's Rake tasks: #{e.message}", log, secrets)
    end

    # When +step+ must be done by: its own timeout or the boot's, whichever
    # comes first.
    def step_deadline(step, deadline)
      step.timeout ? [ deadline, deadline_after(step.timeout) ].min : deadline
    end

    # How a timeout message names the limit that ran out.
    def limit_reached(step, step_deadline, deadline)
      if step&.timeout && step_deadline < deadline
        "within its #{step.timeout}s timeout"
      else
        "within the boot timeout (#{@boot_timeout}s)"
      end
    end

    # The sandbox's own databases (see LocalSandboxDatabases), recorded in
    # state.json before setup can create them: a terminate, in this process
    # or after a restart, drops what is recorded there. Claude Code sessions
    # get them too, so a `bin/rails db:migrate` a session runs lands in the
    # sandbox's database rather than the developer's.
    def assign_databases(workspace, app, overrides, spec)
      plan = LocalSandboxDatabases.plan(
        app: app, workspace: workspace, session_id: workspace.basename.to_s, overrides: overrides,
        fallback_name: spec[:repository].to_s.split("/").last
      )
      if plan.notes.any?
        File.open(log_path(workspace, "setup"), "a") do |file|
          plan.notes.each { |line| file.puts("# sandbox database: #{line}") }
        end
      end
      return {} if plan.empty?

      update_state(workspace) do |state|
        state["database_env"] = plan.env
        state["drop_databases"] = plan.drop
        state["database_drop_targets"] = plan.drop_targets
        state["database_rails_env"] = plan.rails_env
      end
      plan.env
    end

    # Drops the server databases a sandbox was given (PostgreSQL, MySQL),
    # with the checkout's own Rails database tasks: the adapter, its gem and
    # its credentials are the checkout's. Best effort and bounded: a drop
    # that fails or hangs is logged and the sandbox goes anyway. Only ever
    # for the named URLs recorded here. Overridden databases and newly added
    # configurations are never selected, even after the checkout is edited.
    def drop_databases(workspace)
      state = read_state(workspace)
      database_env = state["database_env"]
      targets = state["database_drop_targets"]
      return unless targets.is_a?(Hash) && targets.any? && database_env.is_a?(Hash)

      app = workspace.join("app")
      return unless app.join("bin", "rails").file?

      boot_state = state["boot"]
      file_env =
        if boot_state.is_a?(Hash) && boot_state["mode"] == "spec"
          boot_state.dig("spec", "env").is_a?(Hash) ? boot_state.dig("spec", "env") : {}
        else
          begin
            Config.load(app).env
          rescue Error
            {}
          end
        end
      env = self.class.sanitized_environment.merge(file_env).merge(database_env.transform_values(&:to_s)).merge(
        SESSION_ID_ENV => workspace.basename.to_s,
        "RAILS_ENV" => state.fetch("database_rails_env"),
        DATABASE_DROP_TARGETS_ENV => JSON.generate(targets)
      )
      output, status = capture(env, [ "bin/rails", "runner", DATABASE_DROP_SCRIPT ], chdir: app, limit: 64 * 1024, timeout: database_drop_timeout,
        err: [ :child, :out ])
      return if status&.success?

      Rails.logger.warn("[ActionAgent] sandbox #{workspace.basename}: could not drop its databases " \
        "(#{status ? describe(status) : "timed out"}): #{output.to_s.force_encoding(Encoding::UTF_8).scrub.lines.last(5).join.strip}")
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] sandbox #{workspace.basename}: could not drop its databases: #{e.class.name}: #{e.message}")
    end

    # A method, so the tests can shorten it.
    def database_drop_timeout
      DATABASE_DROP_TIMEOUT
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
        SESSION_ID_ENV => workspace.basename.to_s,
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

    def run_manifest!(workspace, step, env, deadline, secrets)
      path = workspace.join("runtime.json")
      FileUtils.rm_f(path)
      run_step!(workspace, step.label, step.command, env: env, chdir: workspace.join("app"), deadline: deadline, secrets: secrets,
        timeout: step.timeout, log: step.log)

      log = log_path(workspace, step.log)
      fail_step!(step.label, "`#{step.command}` wrote nothing to $#{SandboxManifest::PATH_ENV}", log, secrets) unless path.file?

      read_manifest!(workspace, step, secrets)
    end

    def read_manifest!(workspace, step, secrets)
      path = workspace.join("runtime.json")
      log = log_path(workspace, step.log)
      fail_step!(step.label, "there is no manifest to resume from: resume from manifest", log, secrets) unless path.file?

      # Written by the checkout's command, with its umask: the MCP token in
      # it is for the dashboard alone.
      File.chmod(0o600, path)
      manifest = SandboxManifest.parse(path.read)
      URI.parse("http://127.0.0.1#{manifest["mcp_path"]}")
      manifest
    rescue SandboxManifest::Error, URI::InvalidURIError => e
      fail_step!(step.label, e.message, log, secrets)
    end

    # Runs one boot command to completion in its own process group, with its
    # output in logs/<log>.log, scrubbed of +secrets+ a line at a time on the
    # way there. Anything it left running in that group is stopped too: a
    # setup command is not a way to start services the sandbox never records
    # (that is what `start` is for). +step+ names it in a failure, and
    # +timeout+ bounds it within +deadline+.
    #
    # The group is stopped however the wait ends: a deadline, or any
    # exception at all (a worker shutting down raises into this thread with
    # Thread#raise, which is no StandardError). While it runs its pid is in
    # state.json as step_pid, so a terminate after this process itself died
    # (a crashed dashboard, a killed worker) stops a hung `bundle install`
    # too; nothing else would, the deadline having died with this process.
    def run_step!(workspace, step, command, env:, chdir:, deadline:, secrets:, label: command, timeout: nil, log: step)
      log = log_path(workspace, log)
      File.open(log, "a") { |file| file.puts("$ #{SecretScrubber.scrub(label, secrets)}") }
      until_time = timeout ? [ deadline, deadline_after(timeout) ].min : deadline

      pid = nil
      waiter = nil
      finished = false
      reader, writer = IO.pipe
      copier = nil
      # Deferred until the group is recorded or stopped, so an interrupt
      # never lands between the spawn and the ensure that stops it.
      Thread.handle_interrupt(Object => :never) do
        begin
          pid = spawn_group(env, "sh", "-c", command, chdir: chdir, in: File::NULL, out: writer, err: [ :child, :out ])
        ensure
          writer.close
        end
        begin
          Thread.handle_interrupt(Object => :immediate) do
            record_step(workspace, pid)
            # Started once the step is recorded: until then the group's
            # output waits in the pipe.
            copier = background { copy_output(reader, log, secrets) }
            waiter = Process.detach(pid)
            finished = waiter.join(time_left(until_time))
          end
        ensure
          stop_groups([ pid ], grace: finished ? 1 : stop_grace)
          forget_step(workspace, pid)
          # What the group wrote last is in the log before its tail is read.
          copier&.join(OUTPUT_DRAIN_GRACE)
        end
      end

      unless finished
        limit = timeout && until_time < deadline ? "within its #{timeout}s timeout" : "within the boot timeout (#{@boot_timeout || ActionAgent.local_sandbox_boot_timeout}s)"
        fail_step!(step, "`#{label}` did not finish #{limit}", log, secrets)
      end
      status = waiter.value
      fail_step!(step, "`#{label}` exited with #{describe(status)}", log, secrets) unless status.success?
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end

    # Appends what a boot step prints to +log+, a line at a time, scrubbed.
    def copy_output(io, log, secrets)
      File.open(log, "ab") do |file|
        io.each_line(LOG_LINE_BYTES) do |line|
          file.write(SecretScrubber.scrub(line.force_encoding(Encoding::UTF_8).scrub, secrets))
          file.flush
        end
      end
    rescue IOError
      # Closed under us once the step is over.
    end

    def record_step(workspace, pid)
      update_state(workspace) do |state|
        state["step_pid"] = pid
        record_process_start(state, pid)
      end
    end

    def forget_step(workspace, pid)
      update_state(workspace, create: false) do |state|
        next unless state["step_pid"] == pid

        state.delete("step_pid")
        state_hash(state, "process_starts").delete(pid.to_s)
      end
    rescue SystemCallError
      # The workspace is gone: nothing left to forget it in.
    end

    # The server's output goes to logs/server.log directly, unscrubbed: it
    # outlives this process, and a pipe would end with it. #log_tail and
    # #boot_log scrub it when they read it.
    def start_server(workspace, command, env, port)
      log = log_path(workspace, "server")
      File.open(log, "a") { |file| file.puts("$ #{command}") }

      pid = spawn_group(env, "sh", "-c", command,
        chdir: workspace.join("app"), in: File::NULL, out: [ log.to_s, "a" ], err: [ :child, :out ])
      @server_pid = pid
      # Reaped by this thread for as long as the dashboard lives; after a
      # restart the recorded pid is all that is left, hence state.json.
      waiter = Process.detach(pid)
      recorded = false
      begin
        update_state(workspace) do |state|
          state.merge!("pid" => pid, "port" => port, "started_at" => Time.current.iso8601(3))
          state_hash(state, "code_sessions")
          record_process_start(state, pid)
        end
        recorded = true
      ensure
        # Unrecorded, nothing could ever stop it later, whatever the
        # exception (see #run_step!).
        stop_groups([ pid ]) unless recorded
      end
      [ pid, waiter ]
    end

    # Polls until the MCP path answers, and the answer comes from the
    # server this sandbox started. The port was free when it was picked, but
    # nothing held it after: another process can bind it first, and then
    # answers in the server's place — and would be handed the MCP token.
    def wait_until_ready!(workspace, port, manifest, server_pid, waiter, deadline, secrets, step:, boot_deadline: deadline)
      log = log_path(workspace, "server")
      mcp_path = manifest["mcp_path"]
      uri = URI.parse("http://127.0.0.1:#{port}#{mcp_path}")
      last_status = nil
      foreign = false

      loop do
        unless waiter.alive?
          taken = foreign ? " (another process was listening on port #{port})" : ""
          fail_step!(step.label, "the server exited with #{describe(waiter.value)} before it answered on port #{port}#{taken}",
            log, secrets)
        end

        status = probe(uri)
        if READY_STATUSES.include?(status)
          return if served_by_sandbox?(uri, server_pid, workspace.basename.to_s, manifest["mcp_token"])

          foreign = true
        end

        last_status = status if status
        if monotonic >= deadline
          answered =
            if foreign then " (port #{port} answered, but not from the sandbox's server)"
            elsif last_status then " (last answer: #{last_status})"
            else ""
            end
          fail_step!(step.label, "the server did not answer #{mcp_path} on port #{port} " \
            "#{limit_reached(step, deadline, boot_deadline)}#{answered}", log, secrets)
        end
        sleep POLL_INTERVAL
      end
    end

    # Fails the start step when +start_url+ on the booted server answers 5xx,
    # or never answers. Asked once the MCP facade answered, so the server is
    # the sandbox's own; anything else (a redirect to sign in, a 404) passes.
    def probe_start_url!(workspace, port, start_url, waiter, deadline, secrets, step:, boot_deadline: deadline)
      log = log_path(workspace, "server")
      uri = URI.parse("http://127.0.0.1:#{port}#{start_url}")
      loop do
        read_timeout = [ START_URL_READ_TIMEOUT, time_left(deadline) || START_URL_READ_TIMEOUT ].min
        status = probe(uri, accept: "text/html,*/*", read_timeout: [ read_timeout, 1 ].max)
        if status
          fail_step!(step.label, "GET #{start_url} answered #{status}", log, secrets) if status >= 500
          return status
        end
        unless waiter.alive?
          fail_step!(step.label, "the server exited with #{describe(waiter.value)} before it answered GET #{start_url}", log, secrets)
        end
        if monotonic >= deadline
          fail_step!(step.label, "GET #{start_url} got no answer #{limit_reached(step, deadline, boot_deadline)}", log, secrets)
        end
        sleep POLL_INTERVAL
      end
    rescue URI::InvalidURIError
      fail_step!(step.label, "#{start_url} is not a path this backend can request", log, secrets)
    end

    # Whether what listens on +uri+'s port is the sandbox's server (process
    # group +pgid+). Asked of the system where it can say (/proc on Linux,
    # lsof elsewhere); the token is never sent before. Where it cannot say,
    # the listener must answer as only the sandbox's own MCP facade would:
    # refuse a request without the manifest's token and accept one with it.
    def served_by_sandbox?(uri, pgid, session_id, token)
      owned = sandbox_listener?(uri.port, pgid, session_id)
      return owned unless owned.nil?

      rpc_status(uri, nil) == 401 && rpc_status(uri, token).to_i.between?(200, 299)
    end

    # true or false when the system can say whether the sandbox listens on
    # +port+: a process of the server's group +pgid+ or, where /proc shows
    # environments, one carrying the sandbox's session id (a server that
    # starts its workers in groups of their own). nil when it cannot say.
    def sandbox_listener?(port, pgid, session_id)
      unless procfs?
        listeners = lsof_listeners(port)
        return listeners&.any? { |pid| group_of(pid) == pgid }
      end

      inodes = listening_socket_inodes(port)
      return nil if inodes.blank?
      return true if group_members(pgid).any? { |pid| socket_inodes(pid).intersect?(inodes) }

      # Another user's process does not show its descriptors: whoever holds
      # the socket then is not the sandbox, whose processes are this one's.
      marker = "#{SESSION_ID_ENV}=#{session_id}"
      Dir.children("/proc").any? do |entry|
        next false unless entry.match?(/\A\d+\z/) && socket_inodes(entry).intersect?(inodes)

        File.binread("/proc/#{entry}/environ").split("\0").include?(marker)
      rescue SystemCallError
        false
      end
    end

    # The inodes of the TCP sockets listening on +port+, from
    # /proc/net/tcp and tcp6; nil when neither can be read.
    def listening_socket_inodes(port)
      inodes = nil
      %w[/proc/net/tcp /proc/net/tcp6].each do |table|
        lines = File.readlines(table).drop(1)
        inodes ||= Set.new
        lines.each do |line|
          # sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode
          fields = line.split
          next unless fields[3] == "0A" && fields[1].to_s.split(":").last.to_i(16) == port

          inodes << fields[9]
        end
      rescue SystemCallError
        next
      end
      inodes
    end

    def group_members(pgid)
      Dir.children("/proc").select do |entry|
        next false unless entry.match?(/\A\d+\z/)

        state, _ppid, group = proc_stat(entry)
        group.to_i == pgid && !%w[Z X].include?(state)
      end
    end

    def socket_inodes(pid)
      Dir.children("/proc/#{pid}/fd").filter_map do |fd|
        File.readlink("/proc/#{pid}/fd/#{fd}")[/\Asocket:\[(\d+)\]\z/, 1]
      rescue SystemCallError
        nil
      end.to_set
    rescue SystemCallError
      Set.new
    end

    # The pids listening on +port+ as lsof reports them; nil without lsof.
    def lsof_listeners(port)
      output, _status = Open3.capture2("lsof", "-nP", "-a", "-iTCP:#{port}", "-sTCP:LISTEN", "-Fp", err: File::NULL)
      output.lines.filter_map { |line| Integer(line[/\Ap(\d+)/, 1], exception: false) }
    rescue SystemCallError
      nil
    end

    def group_of(pid)
      Process.getpgid(pid)
    rescue SystemCallError
      nil
    end

    # The HTTP status a JSON-RPC ping to +uri+ answers with, carrying
    # +token+ as its bearer when given; nil while nothing answers.
    def rpc_status(uri, token)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream")
      request["Authorization"] = "Bearer #{token}" if token
      request.body = JSON.generate(jsonrpc: "2.0", id: "readiness", method: "ping")
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = 1
      http.read_timeout = 2
      http.start { |connection| connection.request(request).code.to_i }
    rescue SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse
      nil
    end

    # The HTTP status a GET on +uri+ answers with, or nil while nothing
    # answers.
    def probe(uri, accept: "application/json", read_timeout: 2)
      # No proxy: the dashboard's HTTP(S)_PROXY does not know this loopback.
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = 1
      http.read_timeout = read_timeout
      http.start { |connection| connection.request(Net::HTTP::Get.new(uri, "Accept" => accept)).code.to_i }
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

    def codex_argv(code_session)
      argv = [
        ActionAgent.codex_command.to_s, "exec", "--json", "--ephemeral",
        "--sandbox", "workspace-write", "--config", 'approval_policy="never"', "--color", "never"
      ]
      if (model = code_session.model.presence)
        raise Error, "#{model.inspect} is not a model name" unless MODEL_NAME.match?(model.to_s)

        argv += [ "--model", model.to_s ]
      end
      argv + [ "-" ]
    end

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

    def read_claude_login_status(command)
      output, status = capture(self.class.sanitized_environment, [ command, "auth", "status", "--json" ],
        chdir: Dir.tmpdir, limit: 64 * 1024, timeout: LOGIN_STATUS_TIMEOUT)
      # A logged-out CLI may exit non-zero and still say so; one stopped at
      # the timeout said nothing to trust.
      status.nil? ? LOGGED_OUT : self.class.parse_login_status(output)
    rescue SystemCallError
      LOGGED_OUT
    end

    def run_claude(workspace, code_session, argv, env, secrets, runner: "claude_code", &on_event)
      label = runner == "codex" ? "Codex" : "Claude Code"
      timeout = runner == "codex" ? ActionAgent.codex_timeout : ActionAgent.claude_code_timeout
      key = code_session.id.to_s
      log = log_path(workspace, "#{runner == 'codex' ? 'codex' : 'claude'}-#{key}")
      deadline = deadline_after(timeout)
      # Checked again once Claude Code is recorded; this saves starting it.
      state = read_state(workspace)
      refuse_stopped_session!(state, key, label: label)
      # A cancelled session frees its slot as soon as it is marked cancelled,
      # while its Claude Code may still be exiting (and diffing). Two in one
      # checkout would edit the same files.
      if other_session_running?(state, key, workspace.basename.to_s)
        raise Error, "The previous code session in this sandbox is still stopping; try again in a moment"
      end
      stdin_read, stdin_write = IO.pipe
      stdout_read, stdout_write = IO.pipe
      stderr_read, stderr_write = IO.pipe

      begin
        pid = spawn_group(env, *argv, chdir: workspace.join("app"), in: stdin_read, out: stdout_write, err: stderr_write)
      rescue SystemCallError => e
        raise Error, "Could not start #{label} (#{argv.first}): #{e.message}"
      ensure
        [ stdin_read, stdout_write, stderr_write ].each(&:close)
      end
      waiter = Process.detach(pid)
      # When a cancel was first seen here (monotonic): from then on the
      # session gets STOP_GRACE to end on SIGTERM, then SIGKILL.
      cancel_seen = nil
      case record_code_session(workspace, key, pid)
      when :terminating
        # Stopped by the ensure below, before it had the prompt.
        raise Error, "The sandbox is being stopped, so #{label} did not run"
      when :cancelled
        # Runs its course like any cancelled session: it ends on SIGTERM.
        signal_group(pid, "TERM")
        cancel_seen = monotonic
      end

      # The prompt goes in on stdin, never argv, where `ps` would show it.
      writer = background { write_prompt(stdin_write, code_session.prompt) }
      stderr_tail = []
      reader = background { copy_stderr(stderr_read, log, secrets, stderr_tail) }

      # A cancel sent from another call (or process) is read from
      # state.json, where cancel_code_session notes it.
      next_check = monotonic
      stop_by = lambda do
        if cancel_seen.nil? && monotonic >= next_check
          next_check = monotonic + CANCEL_CHECK_INTERVAL
          cancel_seen = cancel_noted(workspace, key)
        end
        cancel_seen ? [ deadline, cancel_seen + stop_grace ].min : deadline
      end

      finished = stream_events(stdout_read, waiter, stop_by, secrets, &on_event) && waiter.join(time_left(stop_by.call))
      unless finished
        # Cancelled, and SIGTERM did not end it within the grace: SIGKILL,
        # and the session finishes like any cancelled one.
        raise Error, "#{label} did not finish within #{timeout}s and was stopped" unless cancel_seen

        stop_groups([ pid ], grace: 0)
      end

      # Whatever the session left running in the background goes too.
      stop_groups([ pid ], grace: 1)
      reader.join(OUTPUT_DRAIN_GRACE)

      {
        exit_status: waiter.join(OUTPUT_DRAIN_GRACE) ? exit_code(waiter.value) : 128 + Signal.list.fetch("KILL"),
        diff: capture_diff(workspace, secrets),
        stderr_tail: SecretScrubber.scrub(stderr_tail.join("\n"), secrets)
      }
    ensure
      stop_groups([ pid ], grace: cancel_seen ? 0 : stop_grace) if pid
      [ stdin_write, stdout_read, stderr_read ].each { |io| io&.close unless io&.closed? }
      writer&.join(1)
      reader&.join(1)
      forget_code_session(workspace, key)
    end

    # Why a session must not start: a terminate under way, or a cancel that
    # came before there was a process to stop.
    def refuse_stopped_session!(state, key, label: "Claude Code")
      raise Error, "The sandbox is being stopped, so #{label} did not run" if state["terminating"]

      cancels = state["cancelled_code_sessions"]
      raise Error, "#{label} session #{key} was cancelled before it started" if cancels.is_a?(Hash) && cancels.key?(key)
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

    # When a cancel_code_session for session +key+ signalled it, as a
    # monotonic time; nil while none has.
    def cancel_noted(workspace, key)
      at = read_state(workspace).dig("cancelling_code_sessions", key)
      at.is_a?(Numeric) ? monotonic - (Time.now.to_f - at).clamp(0, Float::INFINITY) : nil
    rescue SystemCallError
      nil
    end

    # Reads stream-json from +io+ until it closes, yielding each line as an
    # event. Returns false when the deadline +stop_by+ answers (it can move
    # earlier, on a cancel) passed first.
    def stream_events(io, waiter, stop_by, secrets, &on_event)
      buffer = String.new(encoding: Encoding::BINARY)
      skipping = false
      exited_at = nil

      loop do
        deadline = stop_by.call
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

    # The Claude Code variables a session runs with. An API key comes from
    # the owner's connection. The machine's own login needs none: `claude`
    # finds it itself, and the dashboard neither reads nor passes it on.
    def session_credentials(sandbox, runner: "claude_code")
      return {} if runner == "claude_code" && ClaudeCodeAuth.local_login?

      credentials = (runner == "codex" ? sandbox.runtime_environment(runner: runner) : sandbox.runtime_environment).to_h
      if credentials.empty?
        label = runner == "codex" ? "Codex is not connected: connect an OpenAI API key" : "Claude Code is not connected: connect an Anthropic API key"
        raise Error, "#{label} in Settings → Integrations"
      end

      credentials
    end

    # What a code session's output is scrubbed of. The project's secrets are
    # among them although the session never gets them: the checkout's own
    # files and processes can still show them.
    def sandbox_secrets(sandbox, credentials)
      token = begin
        sandbox.checkout_spec&.dig(:token)
      rescue StandardError
        nil
      end
      [ token, *credentials.values, *Array(sandbox.try(:project_scrub_values)) ].compact.map(&:to_s)
    end

    # Drops the session's pid, and the cancels it may have left.
    def forget_code_session(workspace, key)
      update_state(workspace, create: false) do |state|
        pid = state_hash(state, "code_sessions").delete(key)
        state_hash(state, "process_starts").delete(pid.to_s) if pid
        state_hash(state, "cancelled_code_sessions").delete(key)
        state_hash(state, "cancelling_code_sessions").delete(key)
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

    # TERM to each group, KILL to whatever is left after +grace+ (STOP_GRACE
    # by default), then a moment for the kernel to finish them off.
    def stop_groups(pids, grace: nil)
      grace ||= stop_grace
      live = pids.select { |pid| group_alive?(pid) }
      return if live.empty?

      live.each { |pid| signal_group(pid, "TERM") }
      # Not deadline_after, for which 0 means no limit: here it means none.
      deadline = monotonic + grace
      sleep 0.1 while live.any? { |pid| group_alive?(pid) } && monotonic < deadline

      live.each { |pid| signal_group(pid, "KILL") if group_alive?(pid) }
      deadline = deadline_after(2)
      sleep 0.05 while live.any? { |pid| group_alive?(pid) } && monotonic < deadline
    end

    # A method, not the constant alone, so the tests can shorten it.
    def stop_grace
      STOP_GRACE
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
      # tell a reused pid apart. nil when the process is gone. Written in the
      # local time zone and language, so pinned to UTC and C: a dashboard
      # restarted under another TZ would otherwise read every recorded
      # process as a stranger.
      output, status = Open3.capture2(PS_ENVIRONMENT, "ps", "-o", "lstart=", "-p", pid.to_s)
      status.success? ? output.strip.presence : nil
    rescue SystemCallError
      nil
    end

    def record_process_start(state, pid)
      started = process_start(pid)
      state_hash(state, "process_starts")[pid.to_s] = started if started
    end

    # Whether +pid+, read from state.json, may be signalled as this
    # sandbox's process group (see #group_identity).
    def recorded_group?(pid, session_id, state)
      group_identity(pid, session_id, state) == :ours
    end

    # What +pid+, read from state.json, is now: :ours, :stranger or
    # :unknown. A pid is reused once its process is gone, so where the
    # process is there it must be the one recorded: started when state.json
    # says, or, for a pid recorded without a start time, carrying this
    # sandbox's session id in its environment. Where it is gone there is
    # nothing to confuse: a group id is not reused while any process of the
    # group lives. :unknown when nothing can tell (no start time recorded,
    # and no /proc to read its environment, or no permission to read it):
    # such a pid is never signalled, and never forgotten either.
    def group_identity(pid, session_id, state)
      return :stranger unless signalable?(pid)

      started = state["process_starts"][pid.to_s] if state["process_starts"].is_a?(Hash)
      if started
        current = process_start(pid)
        return current.nil? || current == started ? :ours : :stranger
      end
      return :unknown unless procfs?

      environ = File.binread("/proc/#{pid}/environ")
      if environ.empty?
        # Zombies have no environment and still own their pid. A live
        # process can also have an empty environment, including during exec:
        # without a recorded start time it cannot be identified safely.
        state, = proc_stat(pid)
        return %w[Z X].include?(state) ? :ours : :unknown
      end
      environ.split("\0").include?("#{SESSION_ID_ENV}=#{session_id}") ? :ours : :stranger
    rescue Errno::ENOENT, Errno::ESRCH
      :ours
    rescue Errno::EACCES, Errno::EPERM
      :unknown
    end

    # Stops everything the workspace recorded, then removes it. The
    # terminating mark goes in under the same lock that reads the pids: a
    # Claude Code session that records itself later finds the mark and stops
    # on its own (see #record_code_session), and one that recorded itself
    # earlier is among the pids stopped here.
    #
    # Returns false, keeping the workspace, when a recorded group is still
    # alive afterwards and is not known to be a stranger's: one that could
    # not be stopped, or not told apart from an unrelated process. Removing
    # state.json would drop the only record of it; kept, the next terminate
    # tries again.
    def discard(session_id)
      workspace = workspace_for(session_id)
      return true unless workspace.exist?

      state = begin
        update_state(workspace) { |current| current["terminating"] = true }
      rescue Errno::ENOENT, Errno::ENOTDIR
        {}
      end
      sessions = state["code_sessions"].is_a?(Hash) ? state["code_sessions"].values : []
      recorded = [ state["pid"], state["step_pid"], *sessions ].uniq.select { |pid| signalable?(pid) }
      identities = recorded.index_with { |pid| group_identity(pid, session_id, state) }
      stop_groups(recorded.select { |pid| identities[pid] == :ours })
      stop_escaped(session_id)

      left = recorded.select { |pid| identities[pid] != :stranger && group_alive?(pid) }
      if left.any?
        Rails.logger.error("[ActionAgent] sandbox #{session_id}: process groups #{left.join(", ")} are still alive and " \
          "could not be #{left.any? { |pid| identities[pid] == :unknown } ? "identified" : "stopped"}; " \
          "keeping #{workspace} so a later terminate can try again")
        return false
      end

      # After the server is gone: PostgreSQL refuses to drop a database
      # while anything is connected to it.
      drop_databases(workspace)
      remove_workspace(workspace)
      true
    end

    # Processes of this sandbox that left its process groups (setsid, a
    # daemonizing server) and so escaped #stop_groups, found where /proc
    # shows every process's environment: exactly this sandbox's session id,
    # never this process or its group. One that also rewrote its
    # environment (a long process title) is not found.
    def stop_escaped(session_id)
      return unless procfs?

      marker = "#{SESSION_ID_ENV}=#{session_id}"
      own_group = Process.getpgrp
      escaped = Dir.children("/proc").filter_map do |entry|
        next unless entry.match?(/\A\d+\z/)

        pid = entry.to_i
        next if pid == Process.pid

        state, _ppid, group = proc_stat(entry)
        next if state.nil? || %w[Z X].include?(state) || group.to_i == own_group

        pid if File.binread("/proc/#{pid}/environ").split("\0").include?(marker)
      rescue SystemCallError
        nil
      end
      return if escaped.empty?

      escaped.each { |pid| signal_process(pid, "TERM") }
      deadline = deadline_after(stop_grace)
      sleep 0.1 while escaped.any? { |pid| process_alive?(pid) } && monotonic < deadline
      escaped.each { |pid| signal_process(pid, "KILL") if process_alive?(pid) }
    end

    def signal_process(pid, signal)
      return false unless pid.is_a?(Integer) && pid > 1 && pid != Process.pid

      Process.kill(signal, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def process_alive?(pid)
      state, = proc_stat(pid)
      !state.nil? && !%w[Z X].include?(state)
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

    # No lock needed: state.json is only ever replaced whole (see
    # #update_state), so a read sees one version or the next.
    def read_state(workspace)
      parse_state(File.read(workspace.join("state.json")))
    rescue Errno::ENOENT, Errno::ENOTDIR
      {}
    end

    # Read-modify-write under an exclusive lock: a Claude Code session
    # records its pid while terminate may be reading the same file.
    #
    # The new state goes to a temporary file in the workspace, which is then
    # renamed over state.json: a crash mid-write leaves the old version, not
    # a truncated one. The lock is on state.lock, which is never replaced; a
    # lock on state.json itself would stay on the inode the rename
    # unlinked, and cover nothing. Raises Errno::ENOENT when there is no
    # state.json and +create+ is false, or no workspace at all.
    def update_state(workspace, create: true)
      path = workspace.join("state.json")
      File.open(workspace.join("state.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        current = begin
          File.read(path)
        rescue Errno::ENOENT
          raise unless create

          nil
        end
        state = parse_state(current)
        yield state

        temporary = workspace.join(".state.json.#{SecureRandom.hex(4)}")
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            file.write(JSON.generate(state))
            file.flush
            file.fsync
          end
          File.rename(temporary, path)
        ensure
          FileUtils.rm_f(temporary)
        end
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
