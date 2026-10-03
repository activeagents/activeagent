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
  # A secret has one of two sources:
  #
  #   entered           a value someone typed into the project's secrets form
  #   organization_key  the owner's stored provider key for +provider+,
  #                     resolved at boot and never copied here. Taking it
  #                     needs the consent of whoever set the secret, because
  #                     the repository's code can read it.
  #
  # And one of three kinds. Only an env secret reaches the sandbox's
  # environment; the other two are read by the engine alone, when the
  # project's browser signs in to the app:
  #
  #   env            an environment variable a boot sets
  #   sign_in        a JSON object the explorer's sign_in tool fills a login
  #                  form with (see #sign_in_credentials)
  #   storage_state  a Playwright storage state (cookies and localStorage)
  #                  the project's browser starts with, saved from a browser
  #                  someone signed in by hand
  class ProjectSecret < ApplicationRecord
    include Ownable
    owned_by :account, :user

    SOURCES = %w[entered organization_key].freeze
    KINDS = %w[env sign_in storage_state].freeze
    # The sign-in fields a sign_in secret may hold. login_url is a path on
    # the app; the *_field entries are CSS selectors for when the form's
    # fields cannot be found on their own.
    SIGN_IN_FIELDS = %w[login_url login password login_field password_field submit_field].freeze
    MAX_SELECTOR_LENGTH = 200
    # A storage state's values are scrubbed only when they look like a
    # credential: an httpOnly cookie's, or one at least this long. Shorter
    # values are preferences such as "accepted" or "expanded", which ordinary
    # page text also holds.
    STORAGE_SECRET_MIN_LENGTH = 20
    # A storage state is kept in the value column (text), encrypted; its
    # ciphertext must still fit there.
    MAX_STORAGE_STATE_LENGTH = 40_000
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
    validates :kind, inclusion: { in: KINDS }
    validate :name_allowed
    validate :value_matches_source
    validate :value_matches_kind
    validate :kind_unchanged, on: :update

    scope :ordered, -> { order(:name) }
    scope :env, -> { where(kind: "env") }
    scope :sign_in, -> { where(kind: "sign_in") }
    scope :storage_state, -> { where(kind: "storage_state") }

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

    def env?
      kind == "env"
    end

    def sign_in?
      kind == "sign_in"
    end

    def storage_state?
      kind == "storage_state"
    end

    # A sign_in secret's fields: login_url (a path on the app, "/" when
    # unset), login, password and the optional *_field selectors. Empty for
    # any other secret, or a value that is not a JSON object.
    #
    # @return [Hash{String => String}]
    def sign_in_credentials
      return {} unless sign_in?

      parsed = parse_json_object(value) || {}
      fields = parsed.slice(*SIGN_IN_FIELDS).select { |_name, field| field.is_a?(String) && field.present? }
      fields["login_url"] = "/" if fields["login_url"].blank?
      fields
    end

    # A storage_state secret's state as Playwright reads it, or nil.
    #
    # @return [Hash, nil]
    def storage_state_value
      storage_state? ? parse_json_object(value) : nil
    end

    # The values a sandbox's output, a candidate or a recording is scrubbed
    # of for this secret:
    #
    #   env            its value, the organization's key resolved; none
    #                  once that key is gone
    #   sign_in        its value and the password apart. The login is an
    #                  account name the app shows and mails, so it is kept.
    #   storage_state  its value, and each cookie and localStorage value
    #                  that looks like a credential (STORAGE_SECRET_MIN_LENGTH)
    #
    # @return [Array<String>]
    def scrub_parts
      case kind
      when "sign_in"
        [ value, sign_in_credentials["password"] ].compact
      when "storage_state"
        [ value, *storage_state_credentials ].compact.map(&:to_s)
      else
        [ resolved_value ].compact
      end
    rescue ActiveRecord::RecordNotFound
      []
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
      return self.class.warnings_for(nil, sign_in_credentials["password"]) if sign_in?
      return [] if storage_state?

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
        kind: kind,
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
      elsif env? && [ Project::SIGN_IN_SECRET, Project::STORAGE_STATE_SECRET ].include?(name)
        errors.add(:name, "#{name} keeps the project's sign-in, so an environment variable cannot take it")
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
      elsif value.length > max_value_length || value.include?("\0")
        errors.add(:value, "must be text of at most #{max_value_length} characters")
      end
    end

    def max_value_length
      storage_state? ? MAX_STORAGE_STATE_LENGTH : MAX_VALUE_LENGTH
    end

    def value_matches_kind
      return if env? || value.blank?

      errors.add(:source, "must be entered for a #{kind} secret") if organization_key?
      if sign_in?
        validate_sign_in
      elsif storage_state?
        state = storage_state_value
        unless state && state["cookies"].is_a?(Array) && (state["origins"].nil? || state["origins"].is_a?(Array))
          errors.add(:value, "must be a storage state: a JSON object with a cookies list")
        end
      end
    end

    def validate_sign_in
      fields = parse_json_object(value)
      return errors.add(:value, "must be a JSON object with login_url, login and password") unless fields

      errors.add(:value, "needs a password") unless fields["password"].is_a?(String) && fields["password"].present?
      unless fields["login_url"].blank? || SandboxBootSpec.start_url_path?(fields["login_url"].to_s)
        errors.add(:value, "login_url must be a path on the app, such as /users/sign_in")
      end
      %w[login_field password_field submit_field].each do |field|
        selector = fields[field]
        next if selector.nil?

        unless selector.is_a?(String) && selector.length <= MAX_SELECTOR_LENGTH && !selector.match?(/[\r\n\0]/)
          errors.add(:value, "#{field} must be a CSS selector of at most #{MAX_SELECTOR_LENGTH} characters")
        end
      end
    end

    def storage_state_credentials
      state = storage_state_value || {}
      cookies = Array(state["cookies"]).filter_map do |cookie|
        next unless cookie.is_a?(Hash)

        cookie["value"].to_s if cookie["httpOnly"] == true || cookie["value"].to_s.length >= STORAGE_SECRET_MIN_LENGTH
      end
      stored = Array(state["origins"]).flat_map do |origin|
        next [] unless origin.is_a?(Hash)

        Array(origin["localStorage"]).filter_map do |item|
          item["value"].to_s if item.is_a?(Hash) && item["value"].to_s.length >= STORAGE_SECRET_MIN_LENGTH
        end
      end
      cookies + stored
    end

    def kind_unchanged
      errors.add(:kind, "cannot change: remove #{name} and set it again") if kind_changed?
    end

    def parse_json_object(text)
      parsed = JSON.parse(text.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end
end
