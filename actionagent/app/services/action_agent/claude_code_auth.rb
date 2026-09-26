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
  # Anthropic does not let third-party products store or route requests
  # through Claude.ai subscription credentials, so there is no third mode:
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

    # Why +orchestrator+'s backend cannot run Claude Code sessions with the
    # configured authentication, or nil. A machine's own login is the
    # dashboard user's, so only a backend running sessions as that user, on
    # that machine, may use it: a container or a remote host would either
    # find no login or need it copied there, which is what this mode exists
    # to never do.
    def backend_refusal(orchestrator)
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
    def status(provider_keys)
      if local_login?
        # Only the :local backend uses the login, and no other one needs
        # this machine's CLI asked about it.
        login = local_backend? ? LocalSandboxBackend.claude_login_status : LocalSandboxBackend::LOGGED_OUT
        { mode: mode, connected: login[:logged_in], login: login.slice(:logged_in, :auth_method) }
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
    def credential_refusal(sandbox)
      if local_login?
        return if LocalSandboxBackend.claude_login_status[:logged_in]

        "Claude Code is not logged in on this machine: run `claude /login` as the user the dashboard runs as"
      elsif sandbox.runtime_environment.blank?
        "Claude Code is not connected: connect an Anthropic API key in Settings -> Integrations first"
      end
    end
  end
end
