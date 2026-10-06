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
  #
  # A connection credential (Claude Code) is stored the same way but is not a
  # generation provider: no agent runs "on" it. It is handed to runtimes that
  # need it — a checkout sandbox runs Claude Code sessions with it — through
  # #runtime_environment. For Claude Code that is an Anthropic API key only
  # (see CLAUDE_CODE_CREDENTIAL).
  #
  # A key is an organization key or a personal key, as its scope_key says:
  #
  #   "organization"  the key the owner shares with everyone acting for it
  #   "user:<id>"     one member's own key for an account, used for that
  #                   member's runs when ActionAgent.provider_key_scope is
  #                   :personal_override
  #
  # Personal keys exist only on an install that owns keys per account. They
  # are left out of .for_owner and the dashboard API's `owned`, so a caller
  # that looks a key up by owner and provider reads the organization's.
  # .personal_for is the one way to reach them, and
  # ActionAgent::ProviderCredentials decides when to.
  class ProviderKey < ApplicationRecord
    # Providers that authenticate with an API key.
    KEY_PROVIDERS = %w[openai anthropic openrouter].freeze
    # Providers addressed by host URL instead of a key (with an optional key
    # for remote servers).
    HOST_PROVIDERS = %w[ollama].freeze
    # Tools connected with a credential, configured beside the providers
    # (Settings -> Integrations) but never offered to the agent builder.
    CONNECTION_PROVIDERS = %w[claude_code codex].freeze
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
    CODEX_CREDENTIAL = /\Ask-(?!ant-|or-)[A-Za-z0-9_-]+\z/
    # A Claude subscription token, as earlier versions stored. Recognized so
    # a stored one is never handed out (see #needs_replacing?).
    SUBSCRIPTION_TOKEN_PREFIX = "sk-ant-oat"

    ORGANIZATION_SCOPE = "organization"
    PERSONAL_SCOPE_PREFIX = "user:"
    SCOPE_KEY = /\A(?:organization|user:\d+)\z/

    # Resolver options that point a provider somewhere other than its public
    # endpoint — a proxy or gateway whose key is meant for that endpoint only.
    ENDPOINT_OPTIONS = %w[uri_base base_url api_base host].freeze

    include Ownable
    owned_by :account, :user

    if ActionAgent.encrypt_credentials
      encrypts :credential
      encrypts :api_key
    end

    before_validation :normalize_host_credential, if: :host_based?

    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    validates :scope_key, format: { with: SCOPE_KEY }
    validate :personal_key_allowed, if: :personal?
    # One organization credential per provider per owner, and one personal
    # credential per member, owner and provider. The unique index on
    # (account_id, scope_key, provider) holds the same rule for an
    # account-owned install; which owner column applies depends on the
    # configured mode, so it is also checked at validation time.
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
    validates :credential, format: { with: CODEX_CREDENTIAL, message: "must be an OpenAI API key (sk-…)" },
      if: -> { provider == "codex" }
    validates :api_key, length: { maximum: 500 }, allow_nil: true

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

    # The organization rows: .for_owner and the dashboard API's `owned` read
    # only these.
    def self.owned_rows
      where(scope_key: ORGANIZATION_SCOPE)
    end

    # +actor+'s personal keys for +owner+'s account. None when +actor+ is not
    # a saved instance of ActionAgent.user_class, when +owner+ does not
    # resolve to an account, or when keys are not owned per account (a
    # single-user install, or one that owns keys per user), where no
    # personal key can exist.
    #
    # @return [ActiveRecord::Relation]
    def self.personal_for(owner, actor)
      return none unless owner_association == :account

      user_class = owner_class_for(:user)
      return none unless user_class && actor.is_a?(user_class) && actor.id.present?

      account = resolve_owner(owner)
      return none if account.nil?

      unscoped_by_owner.where(account_id: account.id, scope_key: personal_scope_key(actor))
    end

    # Every key +owner+'s account holds, organization and personal. Only for
    # masking secrets out of output: a credential is read through .for_owner
    # or .personal_for.
    #
    # @return [ActiveRecord::Relation]
    def self.every_scope_for(owner)
      return for_owner(owner) unless owner_association == :account

      account = resolve_owner(owner)
      account ? unscoped_by_owner.where(account_id: account.id) : none
    end

    # Whether this install keeps personal keys: ActionAgent.provider_key_scope
    # is :personal_override and keys are owned per account.
    def self.personal_keys_enabled?
      ActionAgent.provider_key_scope == :personal_override && owner_association == :account
    end

    def self.personal_scope_key(actor)
      "#{PERSONAL_SCOPE_PREFIX}#{actor.id}"
    end

    def self.unscoped_by_owner
      unscope(where: :scope_key)
    end
    private_class_method :unscoped_by_owner

    def self.kind_of_provider(provider)
      if HOST_PROVIDERS.include?(provider) then "host"
      elsif CONNECTION_PROVIDERS.include?(provider) then "connection"
      else "key"
      end
    end

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

    class << self
      # The API keys for +owner+, `{ "openai" => "sk-...", ... }` — one entry
      # per KEY_PROVIDERS provider that has one. Host-addressed providers
      # (ollama) are left out: their credential is a URL, not a key.
      #
      # Each key is looked up in the order generation runs use: the host's
      # `ActionAgent.provider_credentials_resolver`, asked with +owner+, and
      # only when it answers nothing for a provider, the owner's saved row.
      # A resolver answer leaves the provider out when it carries no key
      # (`api_key`/`access_token`) — a run would then use the host's own
      # configuration — or when it also sends the provider to another
      # endpoint (ENDPOINT_OPTIONS), since a gateway's key must not reach the
      # public endpoint a RubyLLM config would pair it with.
      #
      # On an install with an owner model, +owner+ must be an instance of the
      # model this install keeps provider keys by — the configured
      # `account_class`, or `user_class` when there is none — because rows
      # are scoped by its id alone, and another model's id would read someone
      # else's keys. Anything else raises ArgumentError. A nil owner reads no
      # saved rows (only the resolver's keys), and an install with no owner
      # model reads every saved row.
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
        owner = owner_record(owner)
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

      # +owner+ itself — unwrapped from a SimpleDelegator-style decorator —
      # once it is known to be an instance of the owner model.
      def owner_record(owner)
        owner = owner.__getobj__ while defined?(::Delegator) && owner.is_a?(::Delegator)
        association = owner_association
        return owner if owner.nil? || association.nil?

        class_name = ActionAgent.public_send(Ownable::CLASS_FOR.fetch(association))
        owner_class = class_name.to_s.safe_constantize
        raise ArgumentError, "provider keys are kept per #{association}, but #{class_name} does not load" if owner_class.nil?
        return owner if owner.is_a?(owner_class)

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

      # The key a resolver answer carries, in the order the providers' own
      # options read it (`api_key`, then `access_token`), or nil when it
      # carries none or sends the provider to another endpoint.
      def key_from(options)
        return unless options.respond_to?(:to_hash)

        options = options.to_hash.stringify_keys
        return if ENDPOINT_OPTIONS.any? { |name| options[name].present? }

        options["api_key"].presence || options["access_token"].presence
      end
    end

    def host_based?
      HOST_PROVIDERS.include?(provider)
    end

    def personal?
      scope_key.to_s.start_with?(PERSONAL_SCOPE_PREFIX)
    end

    def connection?
      CONNECTION_PROVIDERS.include?(provider)
    end

    # Only host-based providers carry an optional key (a remote Ollama behind
    # an authenticating proxy, or Ollama Cloud).
    def api_key?
      host_based? && api_key.present?
    end

    # Options merged into generate_with for runs owned by this key's owner,
    # overriding the host app's config/active_agent.yml credentials. A
    # connection credential configures no generation.
    def generation_options
      return {} if connection?
      return { access_token: credential } unless host_based?

      { host: credential, access_token: api_key.presence }.compact
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
      if provider == "codex"
        return CODEX_CREDENTIAL.match?(credential.to_s) ? { "CODEX_API_KEY" => credential } : {}
      end
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

    # A personal key needs an account to belong to, and is never a connection
    # credential: those are handed to sandboxes, which every member shares.
    def personal_key_allowed
      if self.class.owner_association != :account || account_id.nil?
        errors.add(:scope_key, "can name a member only when keys are owned per account")
      elsif connection?
        errors.add(:provider, "cannot be a personal key: #{provider} is connected for the whole organization")
      end
    end

    def provider_unique_within_owner
      return if provider.blank?

      siblings = personal? ? self.class.where(account_id: account_id, scope_key: scope_key) : self.class.for_owner(owner)
      siblings = siblings.where.not(id: id) if persisted?
      errors.add(:provider, "has already been taken") if siblings.exists?(provider: provider)
    end
  end
end
