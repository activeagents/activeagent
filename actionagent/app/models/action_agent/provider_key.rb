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
  # #runtime_environment.
  class ProviderKey < ApplicationRecord
    # Providers that authenticate with an API key.
    KEY_PROVIDERS = %w[openai anthropic openrouter].freeze
    # Providers addressed by host URL instead of a key.
    HOST_PROVIDERS = %w[ollama].freeze
    # Tools connected with a credential, configured beside the providers
    # (Settings -> Integrations) but never offered to the agent builder.
    CONNECTION_PROVIDERS = %w[claude_code].freeze
    PROVIDERS = (KEY_PROVIDERS + HOST_PROVIDERS + CONNECTION_PROVIDERS).freeze

    # `claude setup-token` prints a long-lived OAuth token (sk-ant-oat01-…);
    # an Anthropic API key (sk-ant-api03-…) works for Claude Code too.
    CLAUDE_CODE_CREDENTIAL = /\Ask-ant-(oat|api)\d{2}-[A-Za-z0-9_-]+\z/

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
      message: "must be a token from `claude setup-token` (sk-ant-oat…) or an Anthropic API key (sk-ant-api…)"
    }, if: -> { provider == "claude_code" }

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
    # client: Claude Code reads an OAuth token from CLAUDE_CODE_OAUTH_TOKEN
    # and an API key from ANTHROPIC_API_KEY.
    #
    # @return [Hash{String => String}]
    def runtime_environment
      return {} unless provider == "claude_code"

      if credential.start_with?("sk-ant-oat")
        { "CLAUDE_CODE_OAUTH_TOKEN" => credential }
      else
        { "ANTHROPIC_API_KEY" => credential }
      end
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
