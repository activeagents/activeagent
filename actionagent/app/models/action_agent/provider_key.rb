# frozen_string_literal: true

module ActionAgent
  # Per-account LLM provider credential (Settings -> Provider API Keys).
  # Generation runs (AgentExecutionService and the evaluation LLM judge)
  # prefer these over the platform's ENV-configured keys, so users can run
  # agents with their own OpenAI/Anthropic/OpenRouter accounts — or point
  # ollama at their own host (e.g. a tunnel to a locally running instance).
  #
  # The credential is encrypted at rest with Active Record Encryption. API
  # keys are never rendered back to the client — only a masked hint; ollama
  # hosts are not secret and are shown in full (see #display_hint).
  #
  # A connection credential (Claude Code) is stored the same way but is not a
  # generation provider: no agent runs "on" it. It is handed to runtimes that
  # need it — a checkout sandbox runs Claude Code sessions with it — through
  # #runtime_environment. For Claude Code that is an Anthropic API key only
  # (see CLAUDE_CODE_CREDENTIAL).
  class ProviderKey < ApplicationRecord
    # Providers that authenticate with an API key.
    KEY_PROVIDERS = %w[openai anthropic openrouter].freeze
    # Providers addressed by host URL instead of a key.
    HOST_PROVIDERS = %w[ollama].freeze
    # Tools connected with a credential, configured beside the providers
    # (Settings -> Integrations) but never offered to the agent builder.
    CONNECTION_PROVIDERS = %w[claude_code].freeze
    PROVIDERS = (KEY_PROVIDERS + HOST_PROVIDERS + CONNECTION_PROVIDERS).freeze

    # Only an Anthropic API key (sk-ant-api03-…, from the Claude Console or
    # a supported cloud provider). Anthropic does not let third-party
    # products collect, store or route requests through Claude.ai
    # subscription credentials (a `claude setup-token` token, sk-ant-oat…):
    # https://code.claude.com/docs/en/legal-and-compliance.md. A developer
    # who wants their own subscription on their own machine uses
    # ActionAgent.claude_code_auth = :local_login instead, where the
    # dashboard never touches the credential.
    CLAUDE_CODE_CREDENTIAL = /\Ask-ant-api\d{2}-[A-Za-z0-9_-]+\z/
    # A Claude subscription token, as earlier versions stored. Recognized so
    # a stored one is never handed out (see #needs_replacing?).
    SUBSCRIPTION_TOKEN_PREFIX = "sk-ant-oat"

    include Ownable
    owned_by :account, :user

    encrypts :credential if ActionAgent.encrypt_credentials

    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    # One credential per provider per owner; which column that means
    # depends on the configured mode, so it is checked at validation time.
    validate :provider_unique_within_owner
    validates :credential, presence: true, length: { maximum: 500 }
    validates :credential, format: { with: %r{\Ahttps?://\S+\z}, message: "must be an http(s):// URL" },
      if: :host_based?
    validates :credential, format: {
      with: CLAUDE_CODE_CREDENTIAL,
      message: "must be an Anthropic API key (sk-ant-api…) from the Claude Console (https://platform.claude.com). " \
        "Claude subscription tokens (`claude setup-token`, sk-ant-oat…) cannot be stored: Anthropic does not allow " \
        "third-party apps to hold Claude.ai credentials. To use your own Claude login on this machine, set " \
        "ActionAgent.claude_code_auth = :local_login with the :local sandbox backend instead"
    }, if: -> { provider == "claude_code" }

    # Deletes every Claude Code connection that still holds a Claude
    # subscription token (see #needs_replacing?), whoever owns it. The
    # credential is encrypted, so each is read to tell. Their owners see
    # Claude Code as not connected, and connect an API key again.
    #
    # @return [Integer] how many were deleted
    def self.purge_subscription_tokens!
      where(provider: "claude_code").find_each.count do |key|
        key.needs_replacing? && key.destroy!
      end
    end

    def self.kind_of_provider(provider)
      if HOST_PROVIDERS.include?(provider) then "host"
      elsif CONNECTION_PROVIDERS.include?(provider) then "connection"
      else "key"
      end
    end

    def host_based?
      HOST_PROVIDERS.include?(provider)
    end

    def connection?
      CONNECTION_PROVIDERS.include?(provider)
    end

    # Options merged into generate_with for runs owned by this key's owner,
    # overriding the host app's config/active_agent.yml credentials. A
    # connection credential configures no generation.
    def generation_options
      return {} if connection?

      host_based? ? { host: credential } : { access_token: credential }
    end

    # Environment variables a runtime needs to use this credential, for the
    # credentials that are consumed by a process rather than a provider
    # client: Claude Code reads an API key from ANTHROPIC_API_KEY.
    #
    # A subscription token stored before those were refused is never handed
    # to a process: it yields nothing, as if Claude Code were not connected,
    # until it is replaced with an API key.
    #
    # @return [Hash{String => String}]
    def runtime_environment
      return {} unless provider == "claude_code"
      return {} if needs_replacing? || !CLAUDE_CODE_CREDENTIAL.match?(credential.to_s)

      { "ANTHROPIC_API_KEY" => credential }
    end

    # A Claude Code connection that still holds a Claude subscription token
    # (sk-ant-oat…), stored by an earlier version. It is no longer used and
    # must be replaced with an API key; `bin/rails
    # action_agent:claude_code:purge_subscription_tokens` deletes them all.
    def needs_replacing?
      provider == "claude_code" && credential.to_s.start_with?(SUBSCRIPTION_TOKEN_PREFIX)
    end

    # "sk-a…Q2z9" for keys; hosts are shown in full.
    def display_hint
      return credential if host_based?

      "#{credential.first(4)}…#{credential.last(4)}"
    end

    private

    def provider_unique_within_owner
      return if provider.blank?

      siblings = self.class.for_owner(owner)
      siblings = siblings.where.not(id: id) if persisted?
      errors.add(:provider, "has already been taken") if siblings.exists?(provider: provider)
    end
  end
end
