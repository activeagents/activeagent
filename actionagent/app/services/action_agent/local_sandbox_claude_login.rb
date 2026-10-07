# frozen_string_literal: true

require "rbconfig"

module ActionAgent
  module LocalSandboxClaudeLogin
    # The config directory is outside app/, so git, manifests and publishing
    # never enumerate it. The CLI alone reads and writes its credentials.
    def start_claude_login(sandbox)
      workspace, = checkout_workspace!(sandbox)
      directory = workspace.join("claude-login")
      claude_logout(sandbox)
      FileUtils.mkdir_p(directory, mode: 0o700)
      env = sandbox_login_environment(workspace)
      script = File.expand_path("../../../lib/action_agent/claude_login_process.rb", __dir__)
      timeout = (ActionAgent.claude_code_login_timeout || 300).to_f.clamp(1, 600)
      pid = spawn_group(env, RbConfig.ruby, script, directory.to_s, ActionAgent.claude_code_command.to_s, timeout.to_s,
        chdir: workspace, in: File::NULL, out: File::NULL, err: File::NULL)
      update_state(workspace) do |state|
        state["claude_login_pid"] = pid
        record_process_start(state, pid)
      end
      Process.detach(pid)
      # Until the supervisor writes its own state, the flow reads as
      # starting, not as no sign-in at all. Never over a newer state.
      begin
        File.write(directory.join("status.json"), JSON.generate(status: "starting"), mode: "wx", perm: 0o600)
      rescue Errno::EEXIST
        nil
      end
      { status: "starting", logged_in: false, auth_method: nil }
    end

    def submit_claude_login_code(sandbox, code)
      unless code.is_a?(String) && code.match?(/\A[^\s\x00-\x1f\x7f]{1,2048}\z/)
        raise self.class::Error, "Paste the single-use code from Claude's authorization page"
      end
      workspace, = checkout_workspace!(sandbox)
      directory = workspace.join("claude-login")
      update_state(workspace) do |state|
        flow = claude_login_flow(workspace)
        unless flow[:status] == "awaiting_code" && !state["claude_login_submitted"]
          raise self.class::Error, "This sign-in is no longer waiting for a code; start again"
        end
        # The one-use flag is persisted; the code itself is only ever in the
        # request and the pipe. All workers serialize on the workspace lock.
        state["claude_login_submitted"] = true
        File.open(directory.join("code.pipe"), File::WRONLY | File::NONBLOCK | File::NOFOLLOW) do |pipe|
          pipe.write("#{code}\n")
        end
      end
      { status: "submitted", logged_in: false, auth_method: nil }
    rescue Errno::ENOENT, Errno::ENXIO, Errno::EPIPE
      raise self.class::Error, "The sign-in expired; start again"
    end

    def claude_login_status(sandbox)
      workspace, app = checkout_workspace!(sandbox)
      flow = claude_login_flow(workspace)
      if %w[starting awaiting_code submitted].include?(flow[:status])
        state = read_state(workspace)
        pid = state["claude_login_pid"]
        return flow.merge(logged_in: false, auth_method: nil) if pid && group_identity(pid, sandbox.session_id, state) == :ours
        return { status: "expired", logged_in: false, auth_method: nil }
      end
      reject_subscription_overrides!(app)

      output, status = capture(sandbox_login_environment(workspace),
        [ ActionAgent.claude_code_command.to_s, "auth", "status", "--json" ],
        chdir: app, limit: 64 * 1024, timeout: self.class::LOGIN_STATUS_TIMEOUT)
      login = status&.success? ? self.class.parse_login_status(output) : self.class::LOGGED_OUT
      logged_in = login[:logged_in] && login[:auth_method] == "claude.ai"
      # Permission changes never read the credential. Do not follow a link.
      credential = workspace.join("claude", ".credentials.json")
      File.chmod(0o600, credential) if credential.file? && !credential.symlink?
      { status: logged_in ? "connected" : flow[:status], logged_in: logged_in, auth_method: logged_in ? "claude.ai" : nil }
    end

    def claude_logout(sandbox)
      workspace = workspace_for(session_id!(sandbox.session_id))
      logout_claude_workspace(workspace)
      true
    end

    private

    # Project settings are untrusted, and may otherwise silently select API
    # billing instead of the subscription the user explicitly chose.
    def reject_subscription_overrides!(app)
      %w[settings.json settings.local.json].each do |name|
        path = app.join(".claude", name)
        next unless path.exist? || path.symlink?
        raise self.class::Error, "Claude project settings must not be symlinks" if path.symlink? || app.join(".claude").symlink?
        data = JSON.parse(File.read(path, 64 * 1024))
        overrides = data.fetch("env", {}).keys.grep(/\A(?:ANTHROPIC_|CLAUDE_CODE_OAUTH_TOKEN\z)/)
        if data.key?("apiKeyHelper") || overrides.any?
          raise self.class::Error, "Remove Claude project authentication overrides before using a subscription"
        end
      end
    rescue JSON::ParserError, TypeError, NoMethodError
      raise self.class::Error, "Claude project settings must be valid JSON without authentication overrides"
    end

    def claude_login_flow(workspace)
      path = workspace.join("claude-login", "status.json")
      return { status: "disconnected" } unless path.file? && !path.symlink?

      data = JSON.parse(File.read(path, 8192))
      status = data["status"].to_s
      result = { status: %w[starting awaiting_code submitted completed failed expired cancelled].include?(status) ? status : "failed" }
      if status == "awaiting_code" && data["authorize_url"].to_s.match?(%r{\Ahttps://(?:claude\.ai|platform\.claude\.com)/oauth/authorize\?[^\s]+\z})
        result[:authorize_url] = data["authorize_url"]
      end
      result
    rescue JSON::ParserError, Errno::ENOENT
      { status: "disconnected" }
    end

    def sandbox_login_environment(workspace)
      config = workspace.join("claude")
      home = workspace.join("claude-home")
      [ config, home ].each do |directory|
        raise self.class::Error, "Claude configuration must be a private directory" if directory.symlink?
        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
      end
      self.class.sanitized_environment.merge(
        "HOME" => home.to_s, "XDG_CONFIG_HOME" => home.join(".config").to_s,
        "CLAUDE_CONFIG_DIR" => config.to_s, "DISABLE_AUTOUPDATER" => "1",
        self.class::SESSION_ID_ENV => workspace.basename.to_s
      )
    end

    def logout_claude_workspace(workspace)
      return unless workspace.directory?

      state = read_state(workspace)
      pid = state["claude_login_pid"]
      stop_groups([ pid ]) if pid && group_identity(pid, workspace.basename.to_s, state) == :ours
      if workspace.join("claude").directory? && !workspace.join("claude").symlink?
        capture(sandbox_login_environment(workspace), [ ActionAgent.claude_code_command.to_s, "auth", "logout" ],
          chdir: workspace, limit: 1024, timeout: self.class::LOGIN_STATUS_TIMEOUT)
      end
    ensure
      if workspace&.directory?
        %w[claude claude-home claude-login].each { |name| FileUtils.rm_rf(workspace.join(name)) }
        update_state(workspace) { |current| current.delete("claude_login_pid"); current.delete("claude_login_submitted") }
      end
    end
  end
end
