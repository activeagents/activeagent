# frozen_string_literal: true

module ActionAgent
  # An environment variable a project's sandbox boots with, such as the
  # app's own STRIPE_SECRET_KEY.
  #
  # The value is encrypted at rest and never rendered back to the client.
  # A boot hands it to the steps that run the repository's code (setup,
  # manifest and start, see Project#boot_spec), and every log, error and
  # code-session event of the project's sandboxes is scrubbed of it.
  #
  # A secret has one of three sources:
  #
  #   entered           a value someone typed in: into the project's secrets
  #                     form, or as the answer to the setup assistant's
  #                     request_secret
  #   organization_key  the owner's stored provider key for +provider+,
  #                     resolved at boot and never copied here. Taking it
  #                     needs the consent of whoever set the secret, because
  #                     the repository's code can read it.
  #   setup_assistant   a value that is not secret, set by the setup
  #                     assistant's set_env (see ProjectSetup)
  class ProjectSecret < ApplicationRecord
    include Ownable
    owned_by :account, :user

    SOURCES = %w[entered organization_key setup_assistant].freeze
    # The variables "Use the organization's key" is offered for, with the
    # stored provider key each one reads.
    ORGANIZATION_KEY_PROVIDERS = {
      "OPENAI_API_KEY" => "openai",
      "ANTHROPIC_API_KEY" => "anthropic",
      "OPENROUTER_API_KEY" => "openrouter"
    }.freeze
    # Live-mode credential prefixes (Stripe's secret and restricted keys).
    LIVE_PREFIXES = %w[sk_live_ rk_live_].freeze
    MAX_VALUE_LENGTH = 10_000

    belongs_to :project, class_name: "ActionAgent::Project"

    encrypts :value if ActionAgent.encrypt_credentials

    validates :name, presence: true, length: { maximum: 255 }, format: { with: SandboxBootSpec::ENV_NAME, message: "must be an environment variable name" }
    validates :name, uniqueness: { scope: :project_id, case_sensitive: true }
    validates :source, inclusion: { in: SOURCES }
    validate :name_allowed
    validate :value_matches_source

    scope :ordered, -> { order(:name) }

    # Whether +name+ is one the backend sets itself or one that changes how
    # Ruby, Bundler, Node or git load code (SandboxBootSpec::REFUSED_SECRET_NAME).
    def self.refused_name?(name)
      SandboxBootSpec::REFUSED_SECRET_NAME.match?(name.to_s)
    end

    # What the secrets form warns about for +name+ set to +value+, before it
    # is saved: [{ code:, message: }]. A warning never stops a save.
    #
    #   live_credential   a live-mode key, where a test key belongs
    #   short_value       under SecretScrubber::MIN_SECRET_LENGTH characters,
    #                     so logs cannot mask it
    #   rails_master_key  RAILS_MASTER_KEY, better a development or test
    #                     credentials key than production's
    def self.warnings_for(name, value)
      warnings = []
      text = value.to_s
      if LIVE_PREFIXES.any? { |prefix| text.start_with?(prefix) }
        warnings << { code: "live_credential",
                      message: "This looks like a live-mode key. A sandbox runs the repository's code with it: use a test-mode key." }
      end
      if text.present? && text.length < SecretScrubber::MIN_SECRET_LENGTH
        warnings << { code: "short_value",
                      message: "Values under #{SecretScrubber::MIN_SECRET_LENGTH} characters cannot be masked in logs." }
      end
      if name.to_s == "RAILS_MASTER_KEY"
        warnings << { code: "rails_master_key",
                      message: "Prefer the key of development or test credentials over production's." }
      end
      warnings
    end

    def organization_key?
      source == "organization_key"
    end

    # Whether the value is not secret: one the setup assistant set.
    def plain?
      source == "setup_assistant"
    end

    # The value a boot sets the variable to: the entered value, or the
    # owner's stored provider key.
    #
    # @raise [ActiveRecord::RecordNotFound] when the organization's key is
    #   no longer stored
    def resolved_value
      return value unless organization_key?

      key = organization_provider_key or
        raise ActiveRecord::RecordNotFound, "#{name} uses the organization's #{provider} key, which is no longer stored: " \
          "add it in Settings, or enter #{name} for this project"
      key.credential
    end

    def warnings
      self.class.warnings_for(name, organization_key? ? nil : value)
    end

    # The owner's stored provider key for +provider+, or nil. Looked up
    # through ProviderKey's own owner column, which is the project's: both
    # models are owned by the account first. An install that also stores
    # members' personal keys keeps the organization's under scope_key
    # "organization", and only those are read.
    def organization_provider_key
      return nil unless ProviderKey::KEY_PROVIDERS.include?(provider)

      scope = ProviderKey.where(provider: provider)
      scope = scope.where(scope_key: "organization") if ProviderKey.column_names.include?("scope_key")
      case ProviderKey.owner_association
      when :account then project.account_id && scope.find_by(account_id: project.account_id)
      when :user then project.user_id && scope.find_by(user_id: project.user_id)
      else scope.first
      end
    end

    # @param setters [Hash{Integer => Object}] users by id, for set_by
    def as_summary(setters = {})
      setter = set_by_id && setters[set_by_id]
      {
        name: name,
        source: source,
        provider: provider,
        set_by: setter && { id: setter.id, name: self.class.display_name(setter) },
        updated_at: updated_at&.iso8601
      }
    end

    def self.display_name(user)
      user.try(:display_name) || user.try(:name) || user.try(:email_address) || user.try(:email)
    end

    private

    def name_allowed
      return if name.blank?

      if self.class.refused_name?(name)
        errors.add(:name, "#{name} is set by the sandbox or changes how code is loaded, so a project cannot set it")
      end
    end

    def value_matches_source
      if organization_key?
        expected = ORGANIZATION_KEY_PROVIDERS[name]
        if expected.nil?
          errors.add(:source, "organization_key is offered only for #{ORGANIZATION_KEY_PROVIDERS.keys.join(", ")}")
        elsif provider != expected
          errors.add(:provider, "must be #{expected} for #{name}")
        end
        errors.add(:base, "Using the organization's key needs consent to the repository's code reading it") if consented_at.nil?
        errors.add(:value, "must be empty when the organization's key is used") if value.present?
        if expected && provider == expected && organization_provider_key.nil?
          errors.add(:base, "The organization has no #{provider} key to use for #{name}")
        end
      elsif value.blank?
        errors.add(:value, "can't be blank")
      elsif value.length > MAX_VALUE_LENGTH || value.include?("\0")
        errors.add(:value, "must be text of at most #{MAX_VALUE_LENGTH} characters")
      end
    end
  end
end
