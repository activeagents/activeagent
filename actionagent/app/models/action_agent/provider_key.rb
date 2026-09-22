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
  class ProviderKey < ApplicationRecord
    # Providers that authenticate with an API key.
    KEY_PROVIDERS = %w[openai anthropic openrouter].freeze
    # Providers addressed by host URL instead of a key.
    HOST_PROVIDERS = %w[ollama].freeze
    PROVIDERS = (KEY_PROVIDERS + HOST_PROVIDERS).freeze

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

    class << self
      # The owner's saved API keys, `{ "openai" => "sk-...", ... }` — one entry
      # per KEY_PROVIDERS row with a credential. Host-addressed providers
      # (ollama) are left out: their credential is a URL, not a key.
      #
      # A credential that no longer decrypts (a key rotation the row missed)
      # is skipped with a warning rather than raised, so one stale row does not
      # take every provider down with it. The warning names the error class
      # only, never the value.
      #
      # @param owner [Object, nil] whatever `for_owner` scopes by
      # @return [Hash{String => String}]
      def credentials_for(owner)
        for_owner(owner).where(provider: KEY_PROVIDERS).order(:provider).each_with_object({}) do |key, credentials|
          credential = key.credential
          credentials[key.provider] = credential if credential.present?
        rescue StandardError => e
          Rails.logger.warn("[ProviderKey] skipping #{key.provider} credential ##{key.id}: #{e.class.name}")
        end
      end

      # Writes the owner's keys onto `config` through `<provider>_api_key=`
      # writers, the shape a `RubyLLM.context { |config| ... }` block hands
      # out — but any object with those writers will do, so the engine gains
      # no RubyLLM dependency:
      #
      #   context = RubyLLM.context { |config| ActionAgent::ProviderKey.apply_to(config, owner: account) }
      #
      # @param config [Object] anything answering to `openai_api_key=` and friends
      # @param owner [Object, nil] whatever `for_owner` scopes by
      # @return [Hash{String => String}] the credentials applied
      def apply_to(config, owner:)
        credentials_for(owner).each do |provider, credential|
          config.public_send(:"#{provider}_api_key=", credential)
        end
      end
    end

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
      errors.add(:provider, "has already been taken") if siblings.exists?(provider: provider)
    end
  end
end
