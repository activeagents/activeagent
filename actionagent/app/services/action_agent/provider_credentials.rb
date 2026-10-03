# frozen_string_literal: true

module ActionAgent
  # Used to decide which provider credentials a generation runs on: an agent
  # run, the evaluation judge, the dashboard assistant, the model pickers.
  #
  # .resolve tries these sources in order and stops at the first that has
  # options for the provider:
  #
  #   personal       the actor's own ProviderKey for the owner's account,
  #                  only under ActionAgent.provider_key_scope
  #                  :personal_override
  #   host_resolver  ActionAgent.provider_credentials_resolver
  #   organization   the owner's ProviderKey, shared by its members
  #   config         nothing here; config/active_agent.yml has credentials
  #                  for the provider, and the provider reads it and ENV
  #   none           nothing here and nothing in config/active_agent.yml
  #
  # On a multi-tenant install it fails closed: an owner that does not
  # resolve to the configured owner class, or a host resolver that raises,
  # raises Unresolved, so the caller never falls through to the platform's
  # own credentials.
  module ProviderCredentials
    # Raised on a multi-tenant install when credentials cannot be resolved
    # for the owner.
    class Unresolved < StandardError; end

    SOURCES = %w[personal host_resolver organization config none].freeze

    # What .resolve found.
    #
    # @!attribute options
    #   @return [Hash] merged into generate_with, empty for config and none
    # @!attribute source
    #   @return [String] one of SOURCES
    Resolution = Struct.new(:options, :source, keyword_init: true)

    class << self
      # The credentials a generation for +owner+ uses for +provider+, when
      # +actor+ is acting. +actor+ is nil for work no member started (the
      # judge, an unattributed run), which then uses organization keys.
      #
      # @raise [Unresolved] on a multi-tenant install, as described above
      # @return [Resolution]
      def resolve(owner:, provider:, actor: nil)
        provider = provider.to_s
        ensure_owner_resolves!(owner, provider)

        personal = personal_key(owner, actor, provider)&.generation_options
        return Resolution.new(options: personal, source: "personal") if personal.present?

        from_host = ActionAgent.provider_credentials(owner, provider, actor: actor)
        return Resolution.new(options: from_host, source: "host_resolver") if from_host.present?

        organization = ProviderKey.for_owner(owner).find_by(provider: provider)&.generation_options
        return Resolution.new(options: organization, source: "organization") if organization.present?

        Resolution.new(options: {}, source: configured?(provider) ? "config" : "none")
      end

      # Every stored credential of +owner+'s account, organization and
      # personal, for masking out of output. Nil values are dropped.
      #
      # @return [Array<String>]
      def secrets_for(owner, limit:)
        ProviderKey.every_scope_for(owner).limit(limit).pluck(:credential, :api_key).flatten.compact
      end

      private

      def ensure_owner_resolves!(owner, provider)
        return unless ActionAgent.multi_tenant?
        return if ProviderKey.resolve_owner(owner)

        raise Unresolved, "The owner does not resolve to the configured owner class, so no #{provider} credentials apply"
      end

      def personal_key(owner, actor, provider)
        return nil if actor.nil? || !ProviderKey.personal_keys_enabled?

        ProviderKey.personal_for(owner, actor).find_by(provider: provider)
      end

      # Whether config/active_agent.yml carries credentials for +provider+:
      # a host for Ollama, a key for the others.
      def configured?(provider)
        config = ActiveAgent.configuration[provider.to_sym]
        return false unless config.respond_to?(:[])

        provider == "ollama" ? config[:host].present? : (config[:access_token].presence || config[:api_key]).present?
      rescue StandardError
        false
      end
    end
  end
end
