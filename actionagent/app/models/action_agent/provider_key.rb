# frozen_string_literal: true

module ActionAgent
  # Per-account LLM provider credential (Settings -> Provider API Keys).
  # Generation runs (AgentExecutionService and the evaluation LLM judge)
  # prefer these over the platform's ENV-configured keys, so users can run
  # agents with their own OpenAI/Anthropic/OpenRouter accounts — or point
  # ollama at their own host: a locally running instance, a tunnel to one, or
  # a remote/cloud server that additionally needs a Bearer API key.
  #
  # The credential (and the optional api_key) is encrypted at rest with
  # Active Record Encryption. API keys are never rendered back to the client —
  # only a masked hint; ollama hosts are not secret and are shown in full
  # (see #display_hint).
  class ProviderKey < ApplicationRecord
    # Providers that authenticate with an API key.
    KEY_PROVIDERS = %w[openai anthropic openrouter].freeze
    # Providers addressed by host URL instead of a key (with an optional key
    # for remote servers).
    HOST_PROVIDERS = %w[ollama].freeze
    PROVIDERS = (KEY_PROVIDERS + HOST_PROVIDERS).freeze

    include Ownable
    owned_by :account, :user

    if ActionAgent.encrypt_credentials
      encrypts :credential
      encrypts :api_key
    end

    before_validation :normalize_host_credential, if: :host_based?

    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    # One credential per provider per owner; which column that means
    # depends on the configured mode, so it is checked at validation time.
    validate :provider_unique_within_owner
    validates :credential, presence: true, length: { maximum: 500 }
    validates :credential, format: { with: %r{\Ahttps?://\S+\z}, message: "must be an http(s):// URL" },
      if: :host_based?
    validates :api_key, length: { maximum: 500 }, allow_nil: true

    # Ollama's OpenAI-compatible API lives under /v1. Accept the bare server
    # address people naturally paste (http://localhost:11434, a tunnel
    # hostname) and add the path; trailing slashes are dropped so the client
    # can join paths cleanly. An explicit non-root path is left alone, for
    # servers behind a reverse proxy.
    def self.normalize_host(value)
      host = value.to_s.strip.chomp("/")
      return host if host.blank?

      uri = URI.parse(host)
      return host unless uri.is_a?(URI::HTTP)

      uri.path = "/v1" if uri.path.blank? || uri.path == "/"
      uri.to_s.chomp("/")
    rescue URI::InvalidURIError
      host
    end

    def host_based?
      HOST_PROVIDERS.include?(provider)
    end

    # Only host-based providers carry an optional key (a remote Ollama behind
    # an authenticating proxy, or Ollama Cloud).
    def api_key?
      host_based? && api_key.present?
    end

    # Options merged into generate_with for runs owned by this key's owner,
    # overriding the host app's config/active_agent.yml credentials.
    def generation_options
      return { access_token: credential } unless host_based?

      { host: credential, access_token: api_key.presence }.compact
    end

    # "sk-a…Q2z9" for keys; hosts are shown in full.
    def display_hint
      return credential if host_based?

      mask(credential)
    end

    # Masked hint for the optional host-provider key, nil when none is set.
    def api_key_hint
      api_key? ? mask(api_key) : nil
    end

    # Reachability + served models for host-based providers.
    def probe
      OllamaHostProbe.call(host: credential, api_key: api_key)
    end

    private

    def mask(value)
      "#{value.first(4)}…#{value.last(4)}"
    end

    def normalize_host_credential
      self.credential = self.class.normalize_host(credential) if credential.present?
      self.api_key = api_key.presence&.strip
    end

    def provider_unique_within_owner
      return if provider.blank?

      siblings = self.class.for_owner(owner)
      siblings = siblings.where.not(id: id) if persisted?
      errors.add(:provider, "has already been taken") if siblings.exists?(provider: provider)
    end
  end
end
