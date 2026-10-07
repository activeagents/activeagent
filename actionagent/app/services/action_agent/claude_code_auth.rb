# frozen_string_literal: true

module ActionAgent
  # How Claude Code sessions authenticate (ActionAgent.claude_code_auth), and
  # the one rule for whether an owner's Claude Code is "connected", shared by
  # the sandbox listing, the assistant's configuration and the session API so
  # they never disagree.
  #
  # :api_key     the owner's Anthropic API key, stored as a ProviderKey. A
  #              Claude subscription token stored by an earlier version does
  #              not count (ProviderKey#needs_replacing?).
  # :local_login the login of the machine the dashboard runs on, as
  #              `claude auth status` reports it (see
  #              LocalSandboxBackend.claude_login_status). The dashboard never
  #              sees that credential.
  #
  # :sandbox_login is the user's login inside the unmodified CLI. Only the
  # CLI holds its credential; the dashboard relays a one-use login code.
  # https://code.claude.com/docs/en/legal-and-compliance.md
  module ClaudeCodeAuth
    module_function

    # @return [String] "api_key" or "local_login"
    def mode
      ActionAgent.claude_code_auth.to_s
    end

    def local_login?
      mode == "local_login"
    end

    def sandbox_login?
      mode == "sandbox_login"
    end

    LOGIN_VERBS = %i[start_claude_login submit_claude_login_code claude_login_status claude_logout].freeze

    # Why +orchestrator+'s backend cannot run Claude Code sessions with the
    # configured authentication, or nil. A machine's own login is the
    # dashboard user's, so only a backend running sessions as that user, on
    # that machine, may use it: a container or a remote host would either
    # find no login or need it copied there, which is what this mode exists
    # to never do.
    def backend_refusal(orchestrator)
      if sandbox_login?
        unless LOGIN_VERBS.all? { |verb| orchestrator.supports?(verb) }
          return "The #{orchestrator.backend_name} backend does not implement sandbox Claude login (#{LOGIN_VERBS.join(', ')})"
        end
        unless orchestrator.local? || ActionAgent.claude_code_hosted_login_enabled
          return "Hosted Claude subscription login is disabled; the operator must review the hosting requirements and enable it explicitly"
        end
        return
      end
      return unless local_login?
      return if orchestrator.local?

      "ActionAgent.claude_code_auth = :local_login uses this machine's own Claude Code login, so it works only " \
        "with the :local sandbox backend, not #{orchestrator.backend_name}"
    end

    # Whether the owner of +provider_keys+ (a ProviderKey scope already
    # narrowed to them) has an API key Claude Code can run on.
    def api_key_connected?(provider_keys)
      provider_keys.where(provider: "claude_code").any? { |key| key.runtime_environment.present? }
    end

    # What the dashboard reports about Claude Code for the owner of
    # +provider_keys+: booleans and the login's method, never a credential.
    #
    # @return [Hash] { mode:, connected:, login: } (login for :local_login only)
    def status(provider_keys, sandboxes: [], user_id: nil)
      if local_login?
        # Only the :local backend uses the login, and no other one needs
        # this machine's CLI asked about it.
        login = local_backend? ? LocalSandboxBackend.claude_login_status : LocalSandboxBackend::LOGGED_OUT
        { mode: mode, connected: login[:logged_in], login: login.slice(:logged_in, :auth_method) }
      elsif sandbox_login?
        sessions = Array(sandboxes).map { |sandbox| sandbox_status(sandbox, user_id: user_id) }
        { mode: mode, connected: api_key_connected?(provider_keys) || sessions.any? { |row| row[:logged_in] }, sandboxes: sessions }
      else
        { mode: mode, connected: api_key_connected?(provider_keys) }
      end
    end

    # A backend that cannot even be loaded is not the :local one.
    def local_backend?
      SandboxOrchestrator.new.local?
    rescue StandardError, LoadError
      false
    end

    # Why a Claude Code session cannot start in +sandbox+ for want of
    # credentials, or nil.
    def credential_refusal(sandbox, user_id: nil)
      if sandbox_login?
        return if credential_mode(sandbox, user_id: user_id)

        return "Sign in with your own Claude subscription in this sandbox, or connect an Anthropic API key"
      end
      if local_login?
        return if LocalSandboxBackend.claude_login_status[:logged_in]

        "Claude Code is not logged in on this machine: run `claude /login` as the user the dashboard runs as"
      elsif sandbox.runtime_environment.blank?
        "Claude Code is not connected: connect an Anthropic API key in Settings -> Integrations first"
      end
    end

    def credential_mode(sandbox, user_id: nil)
      return mode unless sandbox_login?
      if user_id.present? && sandbox.claude_login_user_id == user_id
        login = SandboxOrchestrator.new.claude_login_status(sandbox)
        return "sandbox_login" if login[:logged_in] && login[:auth_method] == "claude.ai"
      end
      "api_key" if sandbox.runtime_environment.present?
    rescue LocalSandboxBackend::Error, SandboxOrchestrator::UnsupportedBackendError
      "api_key" if sandbox.runtime_environment.present?
    end

    def sandbox_status(sandbox, user_id: nil)
      mine = user_id.present? && sandbox.claude_login_user_id == user_id
      login = if mine && sandbox.ready? && sandbox.active? && !backend_refusal(SandboxOrchestrator.new)
        SandboxOrchestrator.new.claude_login_status(sandbox).slice(:logged_in, :auth_method)
      else
        { logged_in: false, auth_method: nil }
      end
      login = { logged_in: false, auth_method: nil } unless login[:logged_in] && login[:auth_method] == "claude.ai"
      login.merge(session_id: sandbox.session_id, owned_by_you: mine,
        credential_mode: login[:logged_in] ? "sandbox_login" : sandbox.runtime_environment.present? ? "api_key" : nil)
    rescue StandardError
      { session_id: sandbox.session_id, logged_in: false, auth_method: nil, owned_by_you: mine,
        credential_mode: sandbox.runtime_environment.present? ? "api_key" : nil }
    end
  end
end
