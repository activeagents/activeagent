# frozen_string_literal: true

require "fileutils"
require "shellwords"

module ActionAgent
  # Runs a code session in a code-on-incus container, through the `coi` CLI
  # (https://github.com/mensfeld/code-on-incus).
  #
  # coi builds Incus system containers around a coding agent, with nftables
  # network modes, kernel-level threat monitoring, and credentials that are
  # never visible unless explicitly mounted. This backend drives it with one
  # generated profile per session:
  #
  #   <state_dir>/<session_id>/
  #     profile/config.toml   the coi configuration this session runs under
  #     BRIEF.md              the evaluation findings, mounted read-only
  #     PROMPT.md             the task, rewritten per run
  #     secrets/github_token  0600, read by coi's [env_commands] at run time
  #     secrets/env           0600, the coding agent's own provider key
  #     workspace/            the clone, mounted read-write
  #
  # The profile is selected with COI_CONFIG rather than `--profile`, because
  # COI_CONFIG is a trusted-scope path coi reads wherever it lives; a named
  # profile would have to be installed into the operator's coi home first,
  # and per-session profiles do not belong there.
  #
  # Secrets never appear in argv. They are written to 0600 files (over ssh,
  # through the command's standard input) and reach the container through
  # coi's [env_commands], which run inside it. `terminate` deletes the whole
  # state directory, which is what removes them.
  class CodeOnIncusBackend
    class LaunchError < StandardError; end
    class RunError < StandardError; end

    # The clone script. Nothing is interpolated into it: the repository and
    # branch arrive as environment variables the profile sets, so a value
    # like `x; rm -rf /` is a repository name that fails to clone rather
    # than a command. The credential helper feeds the token on stdin of a
    # shell function, so it never reaches argv inside the container either.
    CLONE_SCRIPT = <<~SH
      set -eu
      target=/workspace/repo
      if [ -d "$target/.git" ]; then exit 0; fi
      mkdir -p "$target"
      if [ -n "${GH_TOKEN:-}" ]; then
        git config --global credential.helper '!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
      fi
      if [ -n "${ACTIVE_AGENT_BRANCH:-}" ]; then
        git clone --depth 50 --branch "$ACTIVE_AGENT_BRANCH" "https://github.com/$ACTIVE_AGENT_REPOSITORY.git" "$target"
      else
        git clone --depth 50 "https://github.com/$ACTIVE_AGENT_REPOSITORY.git" "$target"
      fi
    SH

    def initialize(runner: nil, config: nil)
      @config = config || ActionAgent.code_on_incus
      @runner = runner
    end

    # @param session [CodeSession]
    # @param brief [Hash] the compiled brief, written as BRIEF.md
    # @param github_token [String, nil] handed over for the life of the
    #   sandbox; written 0600 and never returned or logged
    def launch(session, brief: {}, github_token: nil)
      state = state_dir(session)
      write_state(session, state, brief: brief, github_token: github_token)

      clone_repository(session, state, github_token) if session.repository.present?

      {
        container_id: profile_name(session),
        workspace_path: File.join(state, "workspace"),
        status: "ready"
      }
    end

    # One headless run. Claude Code goes through coi's own --prompt-file
    # path; every other tool is a plain command inside the container, which
    # is why the catalog marks them experimental.
    def run(session, prompt:)
      state = state_dir(session)
      entry = session.catalog_entry or raise RunError, "Unknown coding agent #{session.tool.inspect}"
      write_file(File.join(state, "PROMPT.md"), prompt.to_s)

      argv = if entry.headless?
        base = [ binary, "run", "--workspace", workspace(state), "--prompt-file", File.join(state, "PROMPT.md") ]
        base + (session.model.present? ? [ "--model", session.model ] : [])
      else
        command = entry.command_for("/brief/PROMPT.md")
        raise RunError, "#{entry.name} cannot be run without attaching to the session" if command.nil?

        [ binary, "run", "--workspace", workspace(state), "--" ] + command
      end

      result = runner(timeout: run_timeout).call(argv, env: coi_env(state))
      transcript = mask(result.output, masking_token(session, state))
      transcript = "#{transcript}\n\n[timed out after #{run_timeout}s]" if result.timed_out?
      tokens = parse_tokens(result.stdout)

      {
        transcript: transcript,
        exit_code: result.exit_code,
        duration_ms: result.duration_ms,
        input_tokens: tokens[:input],
        output_tokens: tokens[:output]
      }
    end

    # What a person runs on their own machine to drive the session
    # interactively. Not executed here: it is copied out of the dashboard.
    def attach_command(session)
      state = state_dir(session)
      argv = [ binary, "attach" ]
      env = coi_env(state)

      if ssh_target.present?
        "ssh -t #{ssh_target} #{Shellwords.escape(env_prefix(env) + argv.shelljoin)}"
      else
        env_prefix(env) + argv.shelljoin
      end
    end

    def status(session)
      result = runner(timeout: 60).call([ binary, "list", "--all" ], env: coi_env(state_dir(session)))
      return { status: "unknown", detail: "coi list failed" } unless result.success?

      line = result.stdout.lines.find { |row| row.include?(profile_name(session)) }
      return { status: "unknown", detail: "not listed" } if line.nil?

      { status: line.match?(/running/i) ? "running" : "stopped", detail: line.strip }
    end

    # Stops the container and removes the state directory, secrets included.
    # Returns whether the state is actually gone, because that is the part
    # that matters: a container that refused to stop is a leak of compute,
    # a token left on disk is a leak of access.
    def terminate(session)
      state = state_dir(session)
      env = coi_env(state)

      result = runner(timeout: 120).call([ binary, "shutdown" ], env: env)
      runner(timeout: 120).call([ binary, "kill" ], env: env) unless result.success?

      remove_state(state)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] code session terminate failed: #{e.message}")
      false
    end

    def supported_tools
      CodeAgentCatalog.all.select { |entry| entry.coi_tool.present? || entry.headless_command.present? }.map(&:key)
    end

    def features
      {
        isolation: "incus system container",
        network: "nftables (restricted / allowlist / open)",
        persistent: false,
        threat_monitoring: true,
        self_hosted: true
      }
    end

    def healthy?
      return @healthy if defined?(@healthy)

      @healthy = runner(timeout: 60).call([ binary, "health" ]).success?
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] coi health check failed: #{e.message}")
      @healthy = false
    end

    # Exposed for the tests and for an operator debugging a session: the
    # exact profile a session runs under.
    def profile_toml(session)
      entry = session.catalog_entry
      state = state_dir(session)
      lines = []

      lines << "# Generated by ActionAgent for code session #{session.session_id}."
      lines << "# Regenerated on every launch; edit ActionAgent.code_on_incus instead."
      lines << "inherits = #{toml(@config[:base_profile] || "hardened")}"
      lines << ""

      if entry&.coi_tool.present?
        lines << "[tool]"
        lines << "name = #{toml(entry.coi_tool)}"
        # Nobody is inside the container to answer a permission prompt.
        lines << 'permission_mode = "bypass"'
        lines << ""
      end

      lines << "[container]"
      lines << "persistent = false"
      lines << "session_name = #{toml(profile_name(session))}"
      lines << "image = #{toml(@config[:image])}" if @config[:image].present?
      lines << ""

      lines << "[network]"
      lines << "mode = #{toml(session.network_mode)}"
      lines << "allowlist = #{toml_array(Array(@config[:allowlist]))}" if session.network_mode == "allowlist"
      lines << "dns_pin = true"
      lines << ""

      lines << "[mounts]"
      lines << "\"/workspace\" = { path = #{toml(workspace(state))}, readonly = false }"
      lines << "\"/brief\" = { path = #{toml(state)}, readonly = true }"
      lines << ""

      lines << "[env]"
      lines << "AGENT_BRIEF_PATH = \"/brief/BRIEF.md\""
      lines << "ACTIVE_AGENT_SESSION_ID = #{toml(session.session_id)}"
      lines << "ACTIVE_AGENT_REPOSITORY = #{toml(session.repository)}" if session.repository.present?
      lines << "ACTIVE_AGENT_BRANCH = #{toml(session.branch)}" if session.branch.present?
      lines << ""

      commands = env_commands(session, state)
      if commands.any?
        lines << "[env_commands]"
        commands.each { |name, command| lines << "#{name} = #{toml(command)}" }
        lines << ""
      end

      lines << "[limits]"
      lines << "cpu_limit = #{toml(@config[:cpu_limit] || "4")}"
      lines << "memory_limit = #{toml(@config[:memory_limit] || "8GB")}"
      lines << "timeout = #{toml(run_timeout.to_s)}"
      lines << ""

      lines << "[security]"
      lines << "workspace_secret_masking = true"
      lines << 'auto_pause_on = "HIGH"'
      lines << 'auto_kill_on = "CRITICAL"'

      "#{lines.join("\n")}\n"
    end

    def state_dir(session)
      File.join(root_dir, session.session_id)
    end

    private

    def binary
      (@config[:binary].presence || "coi").to_s
    end

    def ssh_target
      @config[:ssh_target].presence
    end

    def root_dir
      configured = @config[:state_dir].presence
      return configured.to_s if configured

      Rails.root.join("tmp", "action_agent", "code_sessions").to_s
    end

    def workspace(state)
      File.join(state, "workspace")
    end

    def profile_name(session)
      "action-agent-#{session.session_id.delete("-")[0, 12]}"
    end

    def run_timeout
      ActionAgent.code_session_limits[:run_timeout_seconds].to_i
    end

    # COI_CONFIG points coi at this session's profile. It is trusted scope
    # for coi, which is what lets the profile define prompts and env
    # commands at all.
    def coi_env(state)
      { "COI_CONFIG" => File.join(state, "profile", "config.toml") }
    end

    def env_prefix(env)
      env.map { |key, value| "#{key}=#{Shellwords.escape(value)} " }.join
    end

    def runner(timeout:)
      return @runner if @runner

      prefix = ssh_target.present? ? [ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", ssh_target, "--" ] : []
      CommandRunner.new(prefix: prefix, timeout: timeout)
    end

    # Each credential the coding agent needs, as a command the container
    # runs to read it. The value stays in a 0600 file on the host; only the
    # command to read it is in the profile.
    def env_commands(session, state)
      commands = {}
      secrets = File.join(state, "secrets")

      if session.github_access?
        # 2>/dev/null because the profile is written before we know whether a
        # token resolved: a session granted access whose owner has no token
        # configured gets an empty GH_TOKEN and an anonymous clone (see
        # CLONE_SCRIPT's own guard), rather than an error on every command
        # coi runs in the container.
        read = "cat #{Shellwords.escape(File.join(secrets, "github_token"))} 2>/dev/null"
        commands["GH_TOKEN"] = read
        commands["GITHUB_TOKEN"] = read
      end

      Array(session.catalog_entry&.credential_names).each do |name|
        next if commands.key?(name)

        commands[name] = "sh -c '. #{Shellwords.escape(File.join(secrets, "env"))} 2>/dev/null; printf %s \"$#{name}\"'"
      end

      commands
    end

    def write_state(session, state, brief:, github_token:)
      make_dir(state, 0o700)
      make_dir(File.join(state, "profile"), 0o700)
      make_dir(File.join(state, "secrets"), 0o700)
      make_dir(workspace(state), 0o755)

      write_file(File.join(state, "profile", "config.toml"), profile_toml(session))
      write_file(File.join(state, "BRIEF.md"), brief_markdown(session, brief))
      write_file(File.join(state, "PROMPT.md"), session.task.to_s)
      write_file(File.join(state, "secrets", "github_token"), github_token.to_s, mode: 0o600) if github_token.present?
      write_file(File.join(state, "secrets", "env"), provider_env(session), mode: 0o600)
    end

    # The coding agent's own provider credential, in a file the container
    # sources. Resolved per launch from whatever the host app configured.
    def provider_env(session)
      provider = session.catalog_entry&.provider
      return "" if provider.blank?

      options = ActionAgent.provider_credentials(session.owner, provider)
      token = options[:access_token] || options["access_token"]
      return "" if token.blank?

      name = Array(session.catalog_entry.credentials.first).first
      return "" if name.blank?

      "#{name}=#{Shellwords.escape(token.to_s)}\nexport #{name}\n"
    end

    def brief_markdown(session, brief)
      return brief.to_s if brief.is_a?(String)

      CodeSessionBrief.markdown_for(brief, session: session)
    end

    def clone_repository(session, state, github_token)
      result = runner(timeout: 600).call(
        [ binary, "run", "--workspace", workspace(state), "--", "sh", "-c", CLONE_SCRIPT ],
        env: coi_env(state)
      )
      return if result.success?

      raise LaunchError, "Could not clone #{session.repository}: #{mask(result.output, github_token).to_s.last(600)}"
    end

    # Over ssh the file is written by the remote shell from stdin, so the
    # content never appears in argv. Locally it is a plain write with the
    # mode set before anything is in it.
    def write_file(path, content, mode: 0o644)
      if ssh_target.present?
        remote_write(path, content, mode)
      else
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, mode) { |file| file.write(content) }
        File.chmod(mode, path)
      end
      path
    end

    def remote_write(path, content, mode)
      script = "umask 077; mkdir -p #{Shellwords.escape(File.dirname(path))}; " \
               "cat > #{Shellwords.escape(path)}; chmod #{format("%o", mode)} #{Shellwords.escape(path)}"
      result = runner(timeout: 60).call([ "sh", "-c", script ], stdin: content)
      raise LaunchError, "Could not write #{path} on #{ssh_target}: #{result.stderr}" unless result.success?
    end

    def make_dir(path, mode)
      if ssh_target.present?
        runner(timeout: 60).call([ "mkdir", "-p", "-m", format("%o", mode), path ])
      else
        FileUtils.mkdir_p(path, mode: mode)
      end
    end

    def remove_state(state)
      if ssh_target.present?
        runner(timeout: 60).call([ "rm", "-rf", state ]).success?
      else
        FileUtils.rm_rf(state)
        !File.exist?(state)
      end
    end

    # The token to strike out of a transcript. Resolved rather than read
    # back from disk, because with an ssh target the file lives on the other
    # host: reading it locally would silently find nothing and leave a token
    # a coding agent echoed sitting in the transcript the dashboard renders.
    def masking_token(session, state)
      return nil unless session.github_access?

      resolved = begin
        ActionAgent.github_token_for(session.owner, session)
      rescue StandardError
        nil
      end
      return resolved if resolved.present?

      path = File.join(state, "secrets", "github_token")
      return nil if ssh_target.present? || !File.exist?(path)

      File.read(path).strip.presence
    rescue StandardError
      nil
    end

    # A coding agent that echoes its environment would otherwise put the
    # token in a transcript the dashboard renders.
    def mask(text, token)
      return text if token.blank?

      text.to_s.gsub(token, "[redacted]")
    end

    # Tools print their usage differently and most do not print it at all,
    # so this is best effort and nil is a normal answer.
    def parse_tokens(text)
      input = text[/input tokens?:?\s*([\d,]+)/i, 1]
      output = text[/output tokens?:?\s*([\d,]+)/i, 1]
      {
        input: input&.delete(",")&.to_i,
        output: output&.delete(",")&.to_i
      }
    end

    def toml(value)
      return '""' if value.nil?

      escaped = value.to_s
        .gsub("\\", "\\\\\\\\")
        .gsub('"', '\"')
        .gsub("\n", "\\n")
        .gsub("\r", "\\r")
        .gsub("\t", "\\t")
      "\"#{escaped}\""
    end

    def toml_array(values)
      "[ #{values.map { |value| toml(value) }.join(", ")} ]"
    end
  end
end
