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
      # The API keys the engine's own runs would use for +owner+,
      # `{ "openai" => "sk-...", ... }` — one entry per KEY_PROVIDERS provider
      # that has one. Host-addressed providers (ollama) are left out: their
      # credential is a URL, not a key.
      #
      # A key is looked up the way generation runs look it up: the host's
      # `ActionAgent.provider_credentials_resolver` first, and only when it
      # answers nothing for a provider, the owner's saved row. A resolver
      # answer without a key (`access_token`/`api_key`) leaves the provider
      # out, as a run would then fall back to the host's own configuration.
      #
      # +owner+ must be the model this install keeps provider keys by — the
      # configured `account_class`, or `user_class` when there is none —
      # because rows are scoped by its id alone, and another model's id would
      # read someone else's keys. Anything else raises ArgumentError.
      #
      # A saved credential that no longer decrypts (a key rotation the row
      # missed) is skipped with a warning rather than raised, so one stale row
      # does not take every provider down with it. The warning names the
      # error class only, never the value.
      #
      # @param owner [Object, nil] an instance of the owner model, or nil
      # @return [Hash{String => String}]
      # @raise [ArgumentError] when +owner+ is not an instance of the owner model
      def credentials_for(owner)
        check_owner!(owner)
        saved = nil

        KEY_PROVIDERS.sort.each_with_object({}) do |provider, credentials|
          from_host = ActionAgent.provider_credentials(owner, provider)
          credential = if from_host.present?
            key_from(from_host)
          else
            (saved ||= saved_credentials(owner))[provider]
          end
          credentials[provider] = credential if credential.present?
        end
      end

      # Writes the owner's keys onto `config` through `<provider>_api_key=`
      # writers, the shape a `RubyLLM.context { |config| ... }` block hands
      # out — but any object with those writers will do, so the engine gains
      # no RubyLLM dependency:
      #
      #   context = RubyLLM.context { |config| ActionAgent::ProviderKey.apply_to(config, owner: account) }
      #
      # Only providers with a key are written; the rest keep whatever the
      # config already held (for a `RubyLLM.context`, the host's global keys).
      #
      # @param config [Object] anything answering to `openai_api_key=` and friends
      # @param owner [Object, nil] as for #credentials_for
      # @return [Array<String>] the providers written — never the keys, so the
      #   return value is safe to log
      def apply_to(config, owner:)
        credentials_for(owner).map do |provider, credential|
          config.public_send(:"#{provider}_api_key=", credential)
          provider
        end
      end

      private

      def check_owner!(owner)
        association = owner_association
        return if owner.nil? || association.nil?

        class_name = ActionAgent.public_send(Ownable::CLASS_FOR.fetch(association))
        owner_class = class_name.to_s.safe_constantize
        return if owner_class.nil? || owner.is_a?(owner_class)

        raise ArgumentError,
              "this install keeps provider keys per #{association} (#{class_name}), but was given a #{owner.class.name}"
      end

      def saved_credentials(owner)
        for_owner(owner).where(provider: KEY_PROVIDERS).each_with_object({}) do |key, credentials|
          credentials[key.provider] = key.credential
        rescue StandardError => e
          Rails.logger.warn("[ProviderKey] skipping #{key.provider} credential ##{key.id}: #{e.class.name}")
        end
      end

      def key_from(options)
        options = options.to_h
        options[:access_token] || options["access_token"] || options[:api_key] || options["api_key"]
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
