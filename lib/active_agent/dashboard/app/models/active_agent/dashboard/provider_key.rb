# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Per-account LLM provider credential (Settings -> Provider API Keys).
    # Generation runs (AgentExecutionService and the evaluation LLM judge)
    # prefer these over the platform's ENV-configured keys, so users can run
    # agents with their own OpenAI/Anthropic/OpenRouter accounts — or point
    # ollama at their own host (e.g. a tunnel to a locally running instance).
    #
    # The credential is encrypted at rest with Active Record Encryption. API
    # keys are never rendered back to the client — only a masked hint; ollama
    # hosts are not secret and are shown in full (see #display_hint).
    class ProviderKey < ApplicationRecord
      # Providers that authenticate with an API key.
      KEY_PROVIDERS = %w[openai anthropic openrouter].freeze
      # Providers addressed by host URL instead of a key.
      HOST_PROVIDERS = %w[ollama].freeze
      PROVIDERS = (KEY_PROVIDERS + HOST_PROVIDERS).freeze

      include Ownable

      encrypts :credential if ActiveAgent::Dashboard.encrypt_credentials

      validates :provider, presence: true, inclusion: { in: PROVIDERS }
      # One credential per provider per owner; which column that means
      # depends on the configured mode, so it is checked at validation time.
      validate :provider_unique_within_owner
      validates :credential, presence: true, length: { maximum: 500 }
      validates :credential, format: { with: %r{\Ahttps?://\S+\z}, message: "must be an http(s):// URL" },
        if: :host_based?

      def host_based?
        HOST_PROVIDERS.include?(provider)
      end

      # Options merged into generate_with for runs owned by this key's owner,
      # overriding the host app's config/active_agent.yml credentials.
      def generation_options
        host_based? ? { host: credential } : { access_token: credential }
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
        errors.add(:provider, "already has a credential") if siblings.exists?(provider: provider)
      end
    end
  end
end
