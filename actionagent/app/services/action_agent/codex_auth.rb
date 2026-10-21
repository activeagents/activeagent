# frozen_string_literal: true

module ActionAgent
  # How Codex sessions authenticate (ActionAgent.codex_auth), and the one rule
  # for whether an owner's Codex is "connected", shared by the sandbox
  # listing, the assistant's configuration and the session API so they never
  # disagree. The Codex counterpart of ClaudeCodeAuth.
  #
  # :api_key     the owner's OpenAI API key, stored as a ProviderKey and
  #              handed to the session as CODEX_API_KEY.
  # :local_login the login of the machine the dashboard runs on, as
  #              `codex login status` reports it (see
  #              LocalSandboxBackend.codex_login_status). The dashboard never
  #              sees that credential.
  module CodexAuth
    module_function

    # @return [String] "api_key" or "local_login"
    def mode
      ActionAgent.codex_auth.to_s
    end

    def local_login?
      mode == "local_login"
    end

    # Why +orchestrator+'s backend cannot run Codex sessions with the
    # configured authentication, or nil. A machine's own login is the
    # dashboard user's, so only a backend running sessions as that user, on
    # that machine, may use it: a container or a remote host would either
    # find no login or need it copied there, which is what this mode exists
    # to never do.
    def backend_refusal(orchestrator)
      return unless local_login?
      return if orchestrator.local?

      "ActionAgent.codex_auth = :local_login uses this machine's own Codex login, so it works only " \
        "with the :local sandbox backend, not #{orchestrator.backend_name}"
    end

    # Whether the owner of +provider_keys+ (a ProviderKey scope already
    # narrowed to them) has an API key Codex can run on.
    def api_key_connected?(provider_keys)
      provider_keys.where(provider: "codex").any? { |key| key.runtime_environment.present? }
    end

    # What the dashboard reports about Codex for the owner of
    # +provider_keys+: booleans and the login's method, never a credential.
    #
    # @return [Hash] { mode:, connected:, login: } (login for :local_login only)
    def status(provider_keys)
      if local_login?
        # Only the :local backend uses the login, and no other one needs
        # this machine's CLI asked about it.
        login = local_backend? ? LocalSandboxBackend.codex_login_status : LocalSandboxBackend::LOGGED_OUT
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

    # Why a Codex session cannot start in +sandbox+ for want of credentials,
    # or nil.
    def credential_refusal(sandbox)
      if local_login?
        return if LocalSandboxBackend.codex_login_status[:logged_in]

        "Codex is not logged in on this machine: run `codex login` as the user the dashboard runs as"
      elsif sandbox.runtime_environment(runner: "codex").blank?
        "Codex is not connected: connect an OpenAI API key in Settings -> Integrations first"
      end
    end
  end
end
